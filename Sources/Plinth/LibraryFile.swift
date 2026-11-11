import Foundation

// The model library file (models.json): a lenient read that never loses the seller's library silently.
//
// - A file the app's decoder reads whole loads exactly as before, and is written back with the same encoder as before.
// - Otherwise each entry is read on its own, so one bad entry never drops the rest. An entry this build can't read
//   (one missing its ID, name, file or date, or one from a later version that changed them) is carried through: kept
//   in memory with the same content (keys sorted) and written back after the readable ones on every save, so a newer
//   build (or a repaired file) still has it. Only its Slant file link is ever changed: dropped when that file is
//   replaced, deleted or linked by another model (`libraryCarriedEntriesDroppingLinks`). Only an entry that isn't a JSON object at all, which no version of Plinth writes, is dropped, and it
//   survives in the kept copy.
// - Before anything can replace a file that wasn't fully read, its bytes are kept beside it as
//   `models.unreadable.json` (the Saved Products pattern), never overwriting an earlier kept copy.
// - A missing or empty file is a fresh library and stays silent.

let libraryFileName = "models.json"
/// How many kept copies of a wholly unreadable library may sit beside it (`models.unreadable.json`, then `-2` … `-20`).
let libraryBackupSlotLimit = 20

/// What went wrong reading the library file; nil when it was read whole (or is missing, a fresh library).
enum LibraryFileProblem: Equatable {
    /// The file exists but couldn't be opened (permissions, a disk error), so its bytes couldn't be read.
    case couldNotOpen
    /// The file isn't a list Plinth can read at all; nothing loaded.
    case wholeFileUnreadable
    /// `count` entries couldn't be read; the rest loaded.
    case entriesUnreadable(count: Int)
}

struct LibraryFileRead {
    var models: [LocalModel] = []
    /// Entries this build couldn't read, each a JSON object kept as it was, written back after the readable ones.
    var carriedEntries: [Data] = []
    /// Entries that weren't JSON objects (no version of Plinth writes these); dropped, and kept only in the kept copy.
    var droppedEntries = 0
    var problem: LibraryFileProblem?
}

/// Decodes one model, or nil, so a single damaged entry doesn't discard the rest.
private struct LossyLocalModel: Decodable {
    let value: LocalModel?
    init(from decoder: Decoder) throws { value = try? LocalModel(from: decoder) }
}

/// Reads models.json's bytes. A file the app's decoder reads whole takes the same path as before; otherwise entries
/// are read one by one and the unreadable ones carried through (see the file comment).
func readLibraryFile(_ data: Data) -> LibraryFileRead {
    guard !data.isEmpty else { return LibraryFileRead() }
    if let models = try? JSONDecoder().decode([LocalModel].self, from: data) { return LibraryFileRead(models: models) }
    guard let rows = try? JSONDecoder().decode([LossyLocalModel].self, from: data) else {
        return LibraryFileRead(problem: .wholeFileUnreadable)
    }
    let raw = (try? JSONSerialization.jsonObject(with: data)) as? [Any]
    var result = LibraryFileRead()
    for (index, row) in rows.enumerated() {
        if let model = row.value {
            result.models.append(model)
        } else if let raw, raw.count == rows.count, let object = raw[index] as? [String: Any],
                  let entry = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]) {
            result.carriedEntries.append(entry)
        } else {
            result.droppedEntries += 1
        }
    }
    let unread = result.carriedEntries.count + result.droppedEntries
    result.problem = unread > 0 ? .entriesUnreadable(count: unread) : nil
    return result
}

/// The bytes to write for `models`, followed by the carried entries. With nothing carried this is exactly the
/// encoding the library always used.
func libraryFileData(_ models: [LocalModel], carrying carried: [Data]) throws -> Data {
    let encoder = JSONEncoder()
    guard !carried.isEmpty else { return try encoder.encode(models) }
    let parts = try models.map { try encoder.encode($0) } + carried
    var data = Data("[".utf8)
    for (index, part) in parts.enumerated() {
        if index > 0 { data.append(Data(",".utf8)) }
        data.append(part)
    }
    data.append(Data("]".utf8))
    return data
}

/// Carried entries without a link to any of `fileIDs`: a carried entry is a library model too, so when a Slant file is
/// replaced, deleted or taken by another model, its link (`remoteID`) is dropped like a listed model's. Otherwise a
/// newer build that reads the entry would show a model linked to a file holding another model's bytes, or two models
/// linked to one file. Entries that name none of the files, or can't be parsed, are returned as they were.
func libraryCarriedEntriesDroppingLinks(_ entries: [Data], toFileIDs fileIDs: Set<String>) -> [Data] {
    guard !fileIDs.isEmpty else { return entries }
    return entries.map { entry in
        guard var object = (try? JSONSerialization.jsonObject(with: entry)) as? [String: Any],
              let linked = object["remoteID"] as? String,
              fileIDs.contains(linked) || fileIDs.contains(linked.trimmingCharacters(in: .whitespacesAndNewlines)) else { return entry }
        object.removeValue(forKey: "remoteID")
        return (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])) ?? entry
    }
}

/// `models.unreadable.json` for slot 1, then `models.unreadable-2.json` and so on, beside the library file.
func libraryBackupURL(for library: URL, slot: Int) -> URL {
    let base = library.deletingPathExtension()
    let name = slot <= 1 ? base.lastPathComponent + ".unreadable" : base.lastPathComponent + ".unreadable-\(slot)"
    return base.deletingLastPathComponent().appendingPathComponent(name).appendingPathExtension("json")
}

enum LibraryBackupPlan: Equatable {
    /// An earlier launch already kept these exact bytes here.
    case alreadyKept(URL)
    /// Keep the bytes (or, when the file couldn't be opened, move the file) here.
    case keep(URL)
    /// Nothing to keep: the unread entries are carried through, and an earlier kept copy is never replaced.
    case notNeeded
    /// Every slot holds a different kept copy, so this one can't be kept.
    case noRoom
}

/// Whether the next save would lose something the file holds: everything, for a file that couldn't be read at all,
/// or the dropped entries. Carried entries are written back, so they never count.
func librarySaveWouldLoseData(_ read: LibraryFileRead) -> Bool {
    switch read.problem {
    case nil: return false
    case .couldNotOpen, .wholeFileUnreadable: return true
    case .entriesUnreadable: return read.droppedEntries > 0
    }
}

/// Where to keep a library file that wasn't fully read. Never replaces a kept copy. Identical bytes kept earlier
/// aren't kept again, so repeated launches don't pile copies up. When a save would lose nothing (every unread entry
/// is carried through), the file is kept only in the first slot, so a library rewritten with carried entries on later
/// launches never adds copies; otherwise it takes the first free slot.
func libraryBackupPlan(losesDataOnSave: Bool, data: Data?, library: URL,
                       exists: (URL) -> Bool, contents: (URL) -> Data?) -> LibraryBackupPlan {
    let slots = (1...libraryBackupSlotLimit).map { libraryBackupURL(for: library, slot: $0) }
    if let data, let same = slots.first(where: { exists($0) && contents($0) == data }) { return .alreadyKept(same) }
    guard losesDataOnSave else { return exists(slots[0]) ? .notNeeded : .keep(slots[0]) }
    return slots.first(where: { !exists($0) }).map(LibraryBackupPlan.keep) ?? .noRoom
}

/// What loading the library at launch did.
struct LibraryLoadOutcome {
    var read = LibraryFileRead()
    /// The kept copy's file name (never a path), when this launch kept one or found it kept already.
    var keptCopyName: String?
    /// True when this launch kept a new copy (or moved the file aside), so the seller hears about it once.
    var keptNewCopy = false
    /// Saving would replace a file that couldn't be kept, so saves are refused for this session.
    var saveBlocked = false
}

/// Reads the library at `url`, keeping a copy of a file that wasn't fully read before anything can replace it.
/// `mayMoveFile` is false while Plinth works in Slant Studio's folder (a launch whose folder copy failed): a file that
/// can't be opened is then left where it is, and saving is refused for the session instead, so Slant Studio's library
/// file is never moved or renamed.
func loadLibraryFile(at url: URL, mayMoveFile: Bool = true, fileManager: FileManager = .default) -> LibraryLoadOutcome {
    guard fileManager.fileExists(atPath: url.path) else { return LibraryLoadOutcome() }
    var outcome = LibraryLoadOutcome()
    let data: Data?
    do { data = try Data(contentsOf: url) } catch { data = nil }
    if let data { outcome.read = readLibraryFile(data) } else { outcome.read = LibraryFileRead(problem: .couldNotOpen) }
    guard outcome.read.problem != nil else { return outcome }
    let mustKeep = librarySaveWouldLoseData(outcome.read)
    let plan = libraryBackupPlan(losesDataOnSave: mustKeep, data: data, library: url,
                                 exists: { fileManager.fileExists(atPath: $0.path) },
                                 contents: { try? Data(contentsOf: $0) })
    switch plan {
    case .alreadyKept(let kept):
        outcome.keptCopyName = kept.lastPathComponent
    case .notNeeded:
        break
    case .noRoom:
        outcome.saveBlocked = mustKeep
    case .keep(let target):
        do {
            if let data {
                try data.write(to: target, options: .withoutOverwriting)
            } else if mayMoveFile {
                // Unreadable bytes can't be copied, so the file itself is moved aside.
                try fileManager.moveItem(at: url, to: target)
            } else {
                outcome.saveBlocked = mustKeep
                return outcome
            }
            outcome.keptCopyName = target.lastPathComponent
            outcome.keptNewCopy = true
        } catch {
            outcome.saveBlocked = mustKeep
        }
    }
    return outcome
}

/// The alert shown at launch, or nil. Always for a library that couldn't be read at all, and whenever saving is
/// refused for the session; for unreadable entries otherwise only when this launch kept the copy (later launches show
/// the sidebar note and an Activity line instead of nagging).
func libraryLoadAlertMessage(_ outcome: LibraryLoadOutcome) -> String? {
    guard let problem = outcome.read.problem else { return nil }
    let folder = "Plinth’s support folder (Application Support › Plinth)"
    switch problem {
    case .couldNotOpen, .wholeFileUnreadable:
        let opening = problem == .couldNotOpen ? "Plinth couldn’t open your model library" : "Plinth couldn’t read your model library"
        guard !outcome.saveBlocked, let kept = outcome.keptCopyName else {
            return "\(opening) or keep a copy of it, so the list is empty and library changes won’t be saved this session. Nothing was deleted: your model files are still in the Models folder in \(folder). Quit and reopen Plinth to try again."
        }
        let verb = problem == .couldNotOpen && outcome.keptNewCopy ? "moved aside as" : "kept as"
        return "\(opening), so the list is empty. Nothing was deleted: the file was \(verb) “\(kept)” in \(folder), and your model files are still in the Models folder there."
    case .entriesUnreadable(let count):
        let models = count == 1 ? "1 model" : "\(count) models"
        let listed = count == 1 ? "it isn’t listed" : "they aren’t listed"
        if outcome.saveBlocked {
            return "Plinth couldn’t read \(models) in your library, so \(listed), and couldn’t keep a copy of the library file. Library changes won’t be saved this session, so the file isn’t replaced. Quit and reopen Plinth to try again."
        }
        guard outcome.keptNewCopy, let kept = outcome.keptCopyName else { return nil }
        let entries = outcome.read.droppedEntries == 0
            ? "Plinth keeps the entries unchanged in the library file, where a newer version of Plinth may read them, and kept"
            : "Plinth kept"
        return "Plinth couldn’t read \(models) in your library, so \(listed). \(entries) a copy of the file as “\(kept)” in \(folder)."
    }
}

/// Activity's line for a library that wasn't fully read: counts only, never a path or a name.
func libraryLoadActivityDetail(_ outcome: LibraryLoadOutcome) -> String? {
    guard let problem = outcome.read.problem else { return nil }
    switch problem {
    case .couldNotOpen, .wholeFileUnreadable:
        if outcome.saveBlocked || outcome.keptCopyName == nil { return "Library couldn’t be read or kept; changes aren’t saved this session" }
        return "Library couldn’t be read; a copy was kept"
    case .entriesUnreadable(let count):
        let entries = count == 1 ? "1 entry" : "\(count) entries"
        if outcome.saveBlocked { return "\(entries) couldn’t be read or kept; changes aren’t saved this session" }
        return "\(entries) couldn’t be read; kept in the library file"
    }
}

/// The library list's note while entries are carried through, or nil.
func libraryUnreadableEntriesNote(_ count: Int) -> String? {
    guard count > 0 else { return nil }
    return count == 1
        ? "1 model isn’t listed because this version of Plinth can’t read it. It’s kept in the library file."
        : "\(count) models aren’t listed because this version of Plinth can’t read them. They’re kept in the library file."
}

/// What `saveModels` shows while saving is refused for the session.
let librarySaveBlockedMessage = "Library changes can’t be saved this session, because Plinth couldn’t keep a copy of the library file it couldn’t read. Quit and reopen Plinth to try again."

/// What an upload shows while library saving is refused: the link between a model and its Slant file couldn't be saved.
let libraryUploadBlockedMessage = "Plinth can’t upload this session, because library changes can’t be saved: it couldn’t keep a copy of the library file it couldn’t read. Quit and reopen Plinth to try again."
