import AppKit
import Foundation
import Security
import SwiftUI

// The one-time move from Slant Studio (bundle ID app.slantstudio.mac) to Plinth (io.github.tmm22.plinth).
//
// - Runs only in the packaged Plinth app (`legacyMigrationGate`); under `swift run` or xctest it does nothing.
// - Preferences: every key the new domain lacks is copied once (never overwriting), with order notifications carried
//   as off, because macOS treats Plinth as a new app that needs permission again.
// - Application Support/SlantStudio is copied (never moved or changed) to Application Support/Plinth with the
//   library's file paths rewritten, verified, and only then put in place, carrying a hidden marker file so a crash
//   before the preference marker is never mistaken for a conflict. A failed copy leaves Plinth using the old folder for
//   this launch (`AppSupportLocation`), and it tries again next launch. When both folders hold the seller's data,
//   Plinth's is used and a notice says so until the seller dismisses it.
// - While Slant Studio runs alongside Plinth, a notice asks the seller to quit it: the two apps don't share the
//   unknown-outcome lock, the unconfirmed-draft guard or the quit guard.
// - Keychain items are copied lazily, one account at a time, when a store first reads them (`KeychainItemStore`).
//   Migration never deletes an old item; removing a key in Plinth also tries to remove the old one.
// Nothing here logs a secret or a path.

// The bundle IDs are defined once, in AppIdentity.swift.
let plinthBundleIdentifier = appBundleIdentifier
let legacyBundleIdentifier = legacyAppBundleIdentifier
let plinthKeychainService = "Plinth"
let legacyKeychainService = "SlantStudio"
let plinthSupportFolderName = "Plinth"
let legacySupportFolderName = "SlantStudio"

/// Preference keys the migration itself writes. None is ever copied from the old domain.
enum LegacyMigrationKeys {
    static let prefix = "plinth.migration."
    static let defaults = "plinth.migration.defaults"
    static let supportFolder = "plinth.migration.supportFolder"
    static let keychainAccounts = "plinth.migration.keychainAccounts"
    static let notifyWasOn = "plinth.migration.notifyWasOn"
    /// Launches on which Slant Studio's preferences file existed but couldn't be read.
    static let defaultsUnreadableLaunches = "plinth.migration.defaultsUnreadableLaunches"
}

/// Launches after the first on which an unreadable preferences file is tried again; after them the copy is given up.
let legacyDefaultsUnreadableRetryLimit = 3

/// Which app this build is running as, from its bundle ID.
enum AppIdentity: Equatable, Sendable {
    /// The packaged Plinth app: the only one that migrates.
    case plinth
    /// A build still carrying Slant Studio's bundle ID: it keeps Slant Studio's folder and Keychain service.
    case legacy
    /// `swift run` (no bundle ID) or xctest: Plinth's names, no migration.
    case other
}

func appIdentity(bundleIdentifier: String?) -> AppIdentity {
    switch bundleIdentifier {
    case plinthBundleIdentifier?: return .plinth
    case legacyBundleIdentifier?: return .legacy
    default: return .other
    }
}

/// True only in the packaged Plinth app.
func legacyMigrationGate(bundleIdentifier: String?) -> Bool {
    appIdentity(bundleIdentifier: bundleIdentifier) == .plinth
}

let runningAppIdentity = appIdentity(bundleIdentifier: Bundle.main.bundleIdentifier)

// MARK: Preferences

/// The preference-store calls the migration needs; `UserDefaults` already has them. Tests use an in-memory fake.
protocol MigrationDefaults: AnyObject {
    func object(forKey defaultName: String) -> Any?
    func set(_ value: Any?, forKey defaultName: String)
    func removeObject(forKey defaultName: String)
}

extension UserDefaults: MigrationDefaults {}

enum DefaultsMergeDecision {
    /// The marker is set: the copy already happened.
    case alreadyDone
    /// Slant Studio never saved preferences on this Mac, its file is empty, or it stayed unreadable on every try.
    case nothingToCopy
    /// The old preferences file exists but couldn't be read: try again next launch, with no marker (at most
    /// `legacyDefaultsUnreadableRetryLimit` times).
    case retryLater
    case copy(DefaultsCopy)
}

struct DefaultsCopy {
    /// Keys to set, in key order. `orderWatchNotify` is already carried as false when it was on.
    var values: [(key: String, value: Any)]
    /// Slant Studio had order notifications on: they are carried as off, and the notice says so.
    var turnsOffNotifications: Bool
}

/// What to copy from Slant Studio's preferences: every key the new domain doesn't have, except the migration's own.
/// `unreadableLaunchesSoFar` counts earlier launches that found the file but couldn't read it.
func defaultsMergePlan(legacyDomain: [String: Any]?, legacyPlistExists: Bool, newDomainKeys: Set<String>,
                       markerSet: Bool, unreadableLaunchesSoFar: Int = 0) -> DefaultsMergeDecision {
    if markerSet { return .alreadyDone }
    guard let legacyDomain else {
        guard legacyPlistExists, unreadableLaunchesSoFar < legacyDefaultsUnreadableRetryLimit else { return .nothingToCopy }
        return .retryLater
    }
    // An empty domain (a file with nothing in it) has nothing to bring over; waiting would never change that.
    if legacyDomain.isEmpty { return .nothingToCopy }
    var values: [(key: String, value: Any)] = []
    var turnsOffNotifications = false
    for key in legacyDomain.keys.sorted() where !key.hasPrefix(LegacyMigrationKeys.prefix) && !newDomainKeys.contains(key) {
        guard let value = legacyDomain[key] else { continue }
        if key == orderWatchNotifyDefaultsKey {
            if (value as? Bool) == true { turnsOffNotifications = true }
            values.append((key, false))
        } else {
            values.append((key, value))
        }
    }
    return .copy(DefaultsCopy(values: values, turnsOffNotifications: turnsOffNotifications))
}

/// Writes the copy, then the marker. The notification flag goes first, so a crash part-way still shows the notice
/// after the next launch finishes the copy. Returns the number of keys set.
@discardableResult
func applyDefaultsMerge(_ copy: DefaultsCopy, to defaults: MigrationDefaults) -> Int {
    if copy.turnsOffNotifications { defaults.set(true, forKey: LegacyMigrationKeys.notifyWasOn) }
    for (key, value) in copy.values { defaults.set(value, forKey: key) }
    defaults.set(true, forKey: LegacyMigrationKeys.defaults)
    return copy.values.count
}

// MARK: Application Support folder

/// Files whose presence means a support folder holds the seller's own data (thumbnails alone don't count).
let supportFolderUserDataFiles = ["models.json", "products.json", "products.unreadable.json", "order-watch.json",
                                  "seller-address.json", "seller-address.unreadable.json"]
/// Folders that hold the seller's data when not empty.
let supportFolderUserDataFolders = ["Models", "Removed"]
/// A hidden file the copy carries into Application Support/Plinth before it is put in place: a Plinth folder holding it
/// is the migration's own copy (even after a crash before the preference marker), never a conflict. It is never user
/// data, never compared when verifying, and nothing in the app lists the folder's top level.
let supportFolderMovedMarkerName = ".moved-from-slant-studio"

func supportFolderHasMoveMarker(_ folder: URL, fileManager: FileManager = .default) -> Bool {
    fileManager.fileExists(atPath: folder.appendingPathComponent(supportFolderMovedMarkerName).path)
}

func supportFolderHasUserData(_ folder: URL, fileManager: FileManager = .default) -> Bool {
    for name in supportFolderUserDataFiles where fileManager.fileExists(atPath: folder.appendingPathComponent(name).path) {
        return true
    }
    for name in supportFolderUserDataFolders {
        let contents = (try? fileManager.contentsOfDirectory(atPath: folder.appendingPathComponent(name).path)) ?? []
        if contents.contains(where: { $0 != ".DS_Store" }) { return true }
    }
    return false
}

enum SupportFolderPlan: Equatable {
    /// No Slant Studio data to bring over.
    case nothing
    case copy
    /// A Plinth folder with no user data (for example thumbnails from a development run) is renamed aside first.
    case setAsideThenCopy
    /// Both folders hold user data: Plinth's is used and nothing is merged.
    case conflict
    /// Plinth's folder is the migration's own copy (it carries `supportFolderMovedMarkerName`).
    case alreadyMoved
}

func supportFolderPlan(legacyHasUserData: Bool, newExists: Bool, newHasUserData: Bool,
                       newHasMoveMarker: Bool = false) -> SupportFolderPlan {
    if newExists, newHasMoveMarker { return .alreadyMoved }
    guard legacyHasUserData else { return .nothing }
    guard newExists else { return .copy }
    return newHasUserData ? .conflict : .setAsideThenCopy
}

func supportFolderPlan(legacy: URL, new: URL, fileManager: FileManager = .default) -> SupportFolderPlan {
    var isDirectory: ObjCBool = false
    let newExists = fileManager.fileExists(atPath: new.path, isDirectory: &isDirectory)
    let newIsFolder = newExists && isDirectory.boolValue
    return supportFolderPlan(legacyHasUserData: supportFolderHasUserData(legacy, fileManager: fileManager),
                             newExists: newExists,
                             newHasUserData: newIsFolder && supportFolderHasUserData(new, fileManager: fileManager),
                             newHasMoveMarker: newIsFolder && supportFolderHasMoveMarker(new, fileManager: fileManager))
}

/// The forms of `folder`'s path a saved absolute path may use: as given and with symbolic links resolved.
func supportFolderPathForms(_ folder: URL) -> [String] {
    let plain = folder.standardizedFileURL.path
    let resolved = folder.standardizedFileURL.resolvingSymlinksInPath().path
    return plain == resolved ? [plain] : [plain, resolved]
}

/// `path` moved from inside `legacy` to the same place inside `new`, or nil when it isn't inside `legacy`.
func pathRemappedIntoFolder(_ path: String, legacy: URL, new: URL) -> String? {
    let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
    for prefix in supportFolderPathForms(legacy) where standardized.hasPrefix(prefix + "/") {
        let relative = String(standardized.dropFirst(prefix.count + 1))
        guard !relative.isEmpty else { return nil }
        return new.standardizedFileURL.appendingPathComponent(relative).path
    }
    return nil
}

/// models.json with every `filePath` inside `legacy` rewritten into `new`, every other key and value kept. Nil when
/// nothing changes or the file isn't a library the app's own decoder reads (it is then copied unchanged, and loads in
/// Plinth exactly as it did in Slant Studio).
func modelsJSONRemappingFilePaths(_ data: Data, legacy: URL, new: URL) -> Data? {
    guard (try? JSONDecoder().decode([LocalModel].self, from: data)) != nil,
          var rows = (try? JSONSerialization.jsonObject(with: data)) as? [Any] else { return nil }
    var changed = false
    for index in rows.indices {
        guard var row = rows[index] as? [String: Any], let path = row["filePath"] as? String,
              let remapped = pathRemappedIntoFolder(path, legacy: legacy, new: new) else { continue }
        row["filePath"] = remapped
        rows[index] = row
        changed = true
    }
    guard changed else { return nil }
    return try? JSONSerialization.data(withJSONObject: rows, options: [.withoutEscapingSlashes])
}

/// products.json with any saved-product template path inside `legacy` rewritten into `new`; nil when nothing changes.
func productsJSONRemappingTemplatePaths(_ data: Data, legacy: URL, new: URL) -> Data? {
    guard let object = try? JSONSerialization.jsonObject(with: data) else { return nil }
    var changed = false
    func walk(_ value: Any) -> Any {
        if let dictionary = value as? [String: Any] {
            var result = dictionary
            for (key, inner) in dictionary {
                if key == "templatePath", let path = inner as? String,
                   let remapped = pathRemappedIntoFolder(path, legacy: legacy, new: new) {
                    result[key] = remapped
                    changed = true
                } else {
                    result[key] = walk(inner)
                }
            }
            return result
        }
        if let array = value as? [Any] { return array.map(walk) }
        return value
    }
    let rewritten = walk(object)
    guard changed else { return nil }
    return try? JSONSerialization.data(withJSONObject: rewritten, options: [.withoutEscapingSlashes])
}

/// Every file and folder under `root` (symbolic links not followed) with its size, by relative path.
func supportFolderInventory(_ root: URL, fileManager: FileManager = .default) -> [String: Int]? {
    let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .isSymbolicLinkKey]
    guard let enumerator = fileManager.enumerator(at: root, includingPropertiesForKeys: keys, options: [],
                                                  errorHandler: { _, _ in false }) else { return nil }
    let base = root.standardizedFileURL.resolvingSymlinksInPath().path
    var inventory: [String: Int] = [:]
    for case let url as URL in enumerator {
        guard let values = try? url.resourceValues(forKeys: Set(keys)) else { return nil }
        // Resolve the parent only: a link inside the folder is listed as itself, never as what it points at.
        let parent = url.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath().path
        guard parent == base || parent.hasPrefix(base + "/") else { return nil }
        let relative = String((parent + "/" + url.lastPathComponent).dropFirst(base.count + 1))
        inventory[relative] = values.isDirectory == true && values.isSymbolicLink != true ? -1 : (values.fileSize ?? 0)
    }
    return inventory
}

/// Every field of each model except `filePath`, for comparing a rewritten library with the original.
private func libraryWithoutPaths(_ models: [LocalModel]) -> [Data]? {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    var rows: [Data] = []
    for model in models {
        var copy = model
        copy.filePath = ""
        guard let data = try? encoder.encode(copy) else { return nil }
        rows.append(data)
    }
    return rows
}

/// Checks a finished copy before it is put in place: the same files (models.json and products.json may differ in size,
/// having been rewritten; the copy's own `supportFolderMovedMarkerName` isn't compared), the same library apart from
/// paths, and every remapped model file present when its original exists.
func verifySupportFolderCopy(legacy: URL, copy: URL, finalLocation: URL, fileManager: FileManager = .default) -> Bool {
    guard var original = supportFolderInventory(legacy, fileManager: fileManager),
          var copied = supportFolderInventory(copy, fileManager: fileManager) else { return false }
    original[supportFolderMovedMarkerName] = nil
    copied[supportFolderMovedMarkerName] = nil
    for rewritten in ["models.json", "products.json"] {
        if original[rewritten] != nil, copied[rewritten] != nil { original[rewritten] = 0; copied[rewritten] = 0 }
    }
    guard original == copied else { return false }

    let oldData = try? Data(contentsOf: legacy.appendingPathComponent("models.json"))
    let newData = try? Data(contentsOf: copy.appendingPathComponent("models.json"))
    guard (oldData == nil) == (newData == nil) else { return false }
    guard let oldData, let newData else { return true }
    let oldModels = try? JSONDecoder().decode([LocalModel].self, from: oldData)
    let newModels = try? JSONDecoder().decode([LocalModel].self, from: newData)
    guard let oldModels, let newModels else {
        // A library that doesn't decode is copied byte for byte (it loads as it did in Slant Studio).
        return oldModels == nil && newModels == nil && oldData == newData
    }
    guard oldModels.count == newModels.count, let before = libraryWithoutPaths(oldModels),
          let after = libraryWithoutPaths(newModels), before == after else { return false }
    let finalPrefix = finalLocation.standardizedFileURL.path + "/"
    for (old, new) in zip(oldModels, newModels) where old.filePath != new.filePath {
        guard new.filePath.hasPrefix(finalPrefix) else { return false }
        let inCopy = copy.appendingPathComponent(String(new.filePath.dropFirst(finalPrefix.count))).path
        if fileManager.fileExists(atPath: old.filePath), !fileManager.fileExists(atPath: inCopy) { return false }
    }
    return true
}

enum SupportFolderMigrationResult: Equatable {
    case notNeeded
    /// Copied and put in place; the number of library models it holds.
    case moved(models: Int)
    /// Both folders hold data; Plinth's is used.
    case conflict
    /// Plinth's folder is an earlier launch's copy whose preference marker was never written.
    case alreadyMoved
    /// Something failed; nothing is in place, and the old folder is used this launch.
    case failed
}

let supportFolderMigratingPrefix = ".Plinth-migrating-"
let supportFolderSetAsidePrefix = "Plinth.pre-migration-"

/// Copies `legacy` to `new` (both inside one Application Support folder). The old folder is never changed, an existing
/// Plinth folder with data is never merged into, and one without data is renamed aside, never deleted.
func migrateSupportFolder(legacy: URL, new: URL, fileManager: FileManager = .default) -> SupportFolderMigrationResult {
    let parent = new.deletingLastPathComponent()
    // A copy cut short by a crash or quit.
    if let names = try? fileManager.contentsOfDirectory(atPath: parent.path) {
        for name in names where name.hasPrefix(supportFolderMigratingPrefix) {
            try? fileManager.removeItem(at: parent.appendingPathComponent(name))
        }
    }
    let plan = supportFolderPlan(legacy: legacy, new: new, fileManager: fileManager)
    switch plan {
    case .nothing: return .notNeeded
    case .conflict: return .conflict
    case .alreadyMoved: return .alreadyMoved
    case .setAsideThenCopy:
        let aside = parent.appendingPathComponent(supportFolderSetAsidePrefix + UUID().uuidString)
        do { try fileManager.moveItem(at: new, to: aside) } catch { return .failed }
    case .copy: break
    }
    // Copy what a symbolic link points at, so nothing below can write through a link into the old folder.
    let source = legacy.standardizedFileURL.resolvingSymlinksInPath()
    let temporary = parent.appendingPathComponent(supportFolderMigratingPrefix + UUID().uuidString, isDirectory: true)
    func fail() -> SupportFolderMigrationResult {
        try? fileManager.removeItem(at: temporary)
        return .failed
    }
    do { try fileManager.copyItem(at: source, to: temporary) } catch { return fail() }

    let modelsURL = temporary.appendingPathComponent("models.json")
    if let data = try? Data(contentsOf: modelsURL),
       let rewritten = modelsJSONRemappingFilePaths(data, legacy: legacy, new: new) {
        do { try rewritten.write(to: modelsURL, options: .atomic) } catch { return fail() }
    }
    let productsURL = temporary.appendingPathComponent(savedProductsFileName)
    if let data = try? Data(contentsOf: productsURL),
       let rewritten = productsJSONRemappingTemplatePaths(data, legacy: legacy, new: new) {
        do { try rewritten.write(to: productsURL, options: .atomic) } catch { return fail() }
    }
    // Marks the copy as the migration's own before it can appear under Plinth's name.
    do {
        try Data().write(to: temporary.appendingPathComponent(supportFolderMovedMarkerName), options: .withoutOverwriting)
    } catch { return fail() }
    guard verifySupportFolderCopy(legacy: source, copy: temporary, finalLocation: new, fileManager: fileManager) else {
        return fail()
    }
    // moveItem refuses an existing destination, so a folder that appeared meanwhile is never merged into.
    do { try fileManager.moveItem(at: temporary, to: new) } catch {
        try? fileManager.removeItem(at: temporary)
        if supportFolderHasMoveMarker(new, fileManager: fileManager) { return .alreadyMoved }
        return supportFolderHasUserData(new, fileManager: fileManager) ? .conflict : .failed
    }
    let models = (try? Data(contentsOf: new.appendingPathComponent("models.json")))
        .flatMap { try? JSONDecoder().decode([LocalModel].self, from: $0) }?.count ?? 0
    return .moved(models: models)
}

// MARK: Load-time defence

/// The library with any model still pointing at a file directly inside `<legacy>/Models/` pointed at the same file in
/// `<current>/Models/`, when that file exists. Nil when nothing changes.
func libraryRemappingLegacyModelPaths(_ models: [LocalModel], legacy: URL, current: URL,
                                      fileExists: (String) -> Bool) -> [LocalModel]? {
    let legacyModels = legacy.appendingPathComponent("Models", isDirectory: true)
    guard supportFolderPathForms(legacy) != supportFolderPathForms(current) else { return nil }
    let currentModels = current.appendingPathComponent("Models", isDirectory: true)
    let folders = Set(supportFolderPathForms(legacyModels))
    var changed = false
    var result = models
    for index in result.indices {
        let url = URL(fileURLWithPath: result[index].filePath).standardizedFileURL
        let name = url.lastPathComponent
        guard !name.isEmpty, name != "..", folders.contains(url.deletingLastPathComponent().path) else { continue }
        let remapped = currentModels.appendingPathComponent(name).path
        guard fileExists(remapped) else { continue }
        result[index].filePath = remapped
        changed = true
    }
    return changed ? result : nil
}

// MARK: The old app still running

/// Whether to ask the seller to quit Slant Studio before anything is copied: only while another process runs with
/// Slant Studio's bundle ID and there is still something to bring over.
func legacyAppBlocksMigration(runningLegacyPIDs: [pid_t], ownPID: pid_t, migrationWouldCopy: Bool) -> Bool {
    migrationWouldCopy && runningLegacyPIDs.contains { $0 != ownPID }
}

// MARK: Launch

struct LegacyMigrationOutcome: Equatable, Sendable {
    /// Application Support folder for this launch.
    var supportDirectory: URL
    /// The folder not in use, also refused as an export destination.
    var otherSupportDirectory: URL
    /// The folder copy failed this launch, so Slant Studio's folder is used where it is.
    var copyFailed = false
    /// Counts for Activity; nil when nothing moved this launch.
    var movedModels: Int?
    var movedSettings: Int?
    /// Both folders hold the seller's data, so Plinth kept its own and left Slant Studio's where it is.
    var libraryKeptSeparate = false
    /// Slant Studio's folder, only in the packaged Plinth app (Remove of the seller's address also deletes its copy).
    var slantStudioDirectory: URL?
}

/// Everything the launch step reads, injectable for tests.
struct LegacyMigrationEnvironment {
    var identity: AppIdentity
    var applicationSupport: URL
    var defaults: MigrationDefaults
    var legacyDomain: () -> [String: Any]?
    var legacyPlistExists: Bool
    var newDomainKeys: Set<String>
    var fileManager: FileManager = .default

    var legacyFolder: URL { applicationSupport.appendingPathComponent(legacySupportFolderName, isDirectory: true) }
    var plinthFolder: URL { applicationSupport.appendingPathComponent(plinthSupportFolderName, isDirectory: true) }
}

/// Whether the launch step would copy anything now (preferences or the folder); decides the Quit Slant Studio alert.
/// Preferences count only when they can be read and hold a key Plinth lacks: an empty or unreadable file never makes
/// the seller wait.
func legacyMigrationWouldCopy(_ environment: LegacyMigrationEnvironment) -> Bool {
    guard environment.identity == .plinth else { return false }
    if environment.defaults.object(forKey: LegacyMigrationKeys.defaults) as? Bool != true, environment.legacyPlistExists,
       case .copy(let copy) = defaultsMergePlan(legacyDomain: environment.legacyDomain(), legacyPlistExists: true,
                                                newDomainKeys: environment.newDomainKeys, markerSet: false),
       !copy.values.isEmpty {
        return true
    }
    if environment.defaults.object(forKey: LegacyMigrationKeys.supportFolder) as? Bool == true { return false }
    let plan = supportFolderPlan(legacy: environment.legacyFolder, new: environment.plinthFolder,
                                 fileManager: environment.fileManager)
    return plan == .copy || plan == .setAsideThenCopy
}

/// The launch step: preferences first, then the folder. Decides the folder used for the whole launch.
func performLegacyMigration(_ environment: LegacyMigrationEnvironment) -> LegacyMigrationOutcome {
    let legacy = environment.legacyFolder, plinth = environment.plinthFolder
    switch environment.identity {
    case .legacy: return LegacyMigrationOutcome(supportDirectory: legacy, otherSupportDirectory: plinth)
    case .other: return LegacyMigrationOutcome(supportDirectory: plinth, otherSupportDirectory: legacy)
    case .plinth: break
    }
    var outcome = LegacyMigrationOutcome(supportDirectory: plinth, otherSupportDirectory: legacy,
                                         slantStudioDirectory: legacy)
    let defaults = environment.defaults

    let marker = defaults.object(forKey: LegacyMigrationKeys.defaults) as? Bool == true
    let unreadable = defaults.object(forKey: LegacyMigrationKeys.defaultsUnreadableLaunches) as? Int ?? 0
    switch defaultsMergePlan(legacyDomain: marker ? nil : environment.legacyDomain(),
                             legacyPlistExists: environment.legacyPlistExists,
                             newDomainKeys: environment.newDomainKeys, markerSet: marker,
                             unreadableLaunchesSoFar: unreadable) {
    case .alreadyDone: break
    case .retryLater: defaults.set(unreadable + 1, forKey: LegacyMigrationKeys.defaultsUnreadableLaunches)
    case .nothingToCopy: defaults.set(true, forKey: LegacyMigrationKeys.defaults)
    case .copy(let copy):
        let count = applyDefaultsMerge(copy, to: defaults)
        if count > 0 { outcome.movedSettings = count }
    }

    guard defaults.object(forKey: LegacyMigrationKeys.supportFolder) as? Bool != true else { return outcome }
    switch migrateSupportFolder(legacy: legacy, new: plinth, fileManager: environment.fileManager) {
    case .notNeeded, .alreadyMoved:
        defaults.set(true, forKey: LegacyMigrationKeys.supportFolder)
    case .moved(let models):
        defaults.set(true, forKey: LegacyMigrationKeys.supportFolder)
        outcome.movedModels = models
    case .conflict:
        // Plinth's own data is used. No marker until the seller dismisses the notice: if that folder is removed
        // first, the next launch brings Slant Studio's over.
        outcome.libraryKeptSeparate = true
    case .failed:
        outcome.supportDirectory = legacy
        outcome.otherSupportDirectory = plinth
        outcome.copyFailed = true
    }
    return outcome
}

/// The real launch environment.
func systemLegacyMigrationEnvironment() -> LegacyMigrationEnvironment {
    let manager = FileManager.default
    let applicationSupport = manager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    let library = manager.urls(for: .libraryDirectory, in: .userDomainMask)[0]
    let plist = library.appendingPathComponent("Preferences/\(legacyBundleIdentifier).plist")
    let identity = runningAppIdentity
    let newKeys = Set(Bundle.main.bundleIdentifier.flatMap { UserDefaults.standard.persistentDomain(forName: $0) }?.keys
        .map { $0 } ?? [])
    return LegacyMigrationEnvironment(
        identity: identity, applicationSupport: applicationSupport, defaults: UserDefaults.standard,
        legacyDomain: { UserDefaults.standard.persistentDomain(forName: legacyBundleIdentifier) },
        legacyPlistExists: manager.fileExists(atPath: plist.path), newDomainKeys: newKeys, fileManager: manager)
}

enum LegacyMigrationLaunch {
    /// Decided once per launch, on first use (after the Quit Slant Studio alert, which runs first).
    static let outcome: LegacyMigrationOutcome = performLegacyMigration(systemLegacyMigrationEnvironment())
}

/// The Application Support folder for this launch. Every use of Studio's support folder goes through it.
enum AppSupportLocation {
    static var directory: URL { LegacyMigrationLaunch.outcome.supportDirectory }
    /// The other app's folder: never written, and refused as an export destination.
    static var otherDirectory: URL { LegacyMigrationLaunch.outcome.otherSupportDirectory }
    static var copyFailedThisLaunch: Bool { LegacyMigrationLaunch.outcome.copyFailed }
    static var libraryKeptSeparateThisLaunch: Bool { LegacyMigrationLaunch.outcome.libraryKeptSeparate }
    /// Slant Studio's folder, only in the packaged Plinth app; nil otherwise. Used only to delete the seller's address.
    static var slantStudioDirectory: URL? { LegacyMigrationLaunch.outcome.slantStudioDirectory }
}

@MainActor enum LegacyMigration {
    private static var started = false

    /// Runs once, before anything reads preferences, the Keychain or the support folder. Called from the App's
    /// `init()`, and again (doing nothing) from the app delegate and the store.
    static func runAtLaunch() {
        guard !started else { return }
        started = true
        if runningAppIdentity == .plinth { waitForSlantStudioToQuit() }
        _ = LegacyMigrationLaunch.outcome
    }

    /// Asks the seller to quit Slant Studio while it runs and there is something to copy. Nothing is touched meanwhile.
    private static func waitForSlantStudioToQuit() {
        let me = ProcessInfo.processInfo.processIdentifier
        func blocked() -> Bool {
            let running = NSRunningApplication.runningApplications(withBundleIdentifier: legacyBundleIdentifier)
                .map(\.processIdentifier)
            guard !running.isEmpty else { return false }
            return legacyAppBlocksMigration(runningLegacyPIDs: running, ownPID: me,
                                            migrationWouldCopy: legacyMigrationWouldCopy(systemLegacyMigrationEnvironment()))
        }
        while blocked() {
            let app = NSApplication.shared
            app.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = "Quit Slant Studio first"
            alert.informativeText = "Plinth can bring over your library, keys and settings only after Slant Studio has quit. Quit it, then choose Try Again."
            alert.addButton(withTitle: "Try Again")
            alert.addButton(withTitle: "Quit Plinth")
            if alert.runModal() == .alertSecondButtonReturn { exit(0) }
        }
    }
}

/// Activity's one line about the move: counts only, never paths or secrets, and no zero counts. Nil when nothing was
/// counted this launch.
func legacyMigrationActivityDetail(_ outcome: LegacyMigrationOutcome) -> String? {
    var parts: [String] = []
    if let models = outcome.movedModels, models > 0 { parts.append(models == 1 ? "1 model" : "\(models) models") }
    if let settings = outcome.movedSettings, settings > 0 {
        parts.append(settings == 1 ? "1 setting" : "\(settings) settings")
    }
    return parts.isEmpty ? nil : parts.joined(separator: " · ")
}

/// Activity's line when both folders hold the seller's data: no paths. Nil otherwise.
func legacyMigrationKeptSeparateActivity(_ outcome: LegacyMigrationOutcome) -> (title: String, detail: String)? {
    guard outcome.libraryKeptSeparate else { return nil }
    return (legacyLibraryKeptSeparateActivityTitle, legacyLibraryKeptSeparateActivityDetail)
}

// MARK: Keychain

enum KeychainRead: Equatable {
    case found(Data)
    case notFound
    /// The item exists but its value isn't data.
    case unreadableValue
    case failed(OSStatus)
}

/// The Keychain calls the stores make, injectable so tests never touch the real Keychain.
protocol KeychainBackend: Sendable {
    func read(service: String, account: String) -> KeychainRead
    /// Adds a generic password readable only on this Mac while it is unlocked.
    func add(service: String, account: String, data: Data) -> OSStatus
    func update(service: String, account: String, data: Data) -> OSStatus
    func delete(service: String, account: String) -> OSStatus
}

struct SystemKeychainBackend: KeychainBackend {
    private func query(_ service: String, _ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    func read(service: String, account: String) -> KeychainRead {
        var attributes = query(service, account)
        attributes[kSecReturnData as String] = true
        attributes[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(attributes as CFDictionary, &result)
        if status == errSecItemNotFound { return .notFound }
        guard status == errSecSuccess else { return .failed(status) }
        guard let data = result as? Data else { return .unreadableValue }
        return .found(data)
    }

    func add(service: String, account: String, data: Data) -> OSStatus {
        var attributes = query(service, account)
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        return SecItemAdd(attributes as CFDictionary, nil)
    }

    func update(service: String, account: String, data: Data) -> OSStatus {
        SecItemUpdate(query(service, account) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
    }

    func delete(service: String, account: String) -> OSStatus {
        SecItemDelete(query(service, account) as CFDictionary)
    }
}

/// Accounts already brought over, saved or removed in Plinth: Slant Studio's item is never read for them again, so a
/// removed key never comes back.
protocol KeychainTombstones: Sendable {
    func contains(_ account: String) -> Bool
    func insert(_ account: String)
}

struct DefaultsKeychainTombstones: KeychainTombstones {
    private static let lock = NSLock()

    func contains(_ account: String) -> Bool {
        Self.lock.withLock {
            (UserDefaults.standard.stringArray(forKey: LegacyMigrationKeys.keychainAccounts) ?? []).contains(account)
        }
    }

    func insert(_ account: String) {
        Self.lock.withLock {
            var accounts = UserDefaults.standard.stringArray(forKey: LegacyMigrationKeys.keychainAccounts) ?? []
            guard !accounts.contains(account) else { return }
            accounts.append(account)
            UserDefaults.standard.set(accounts, forKey: LegacyMigrationKeys.keychainAccounts)
        }
    }
}

enum KeychainValue: Equatable {
    case none
    case data(Data)
    /// The item exists but its value can't be read; each store reports this with its own message.
    case unreadable
}

/// One Keychain account, under Plinth's service, read from Slant Studio's service the first time when migrating.
struct KeychainItemStore: Sendable {
    let account: String
    let service: String
    /// Slant Studio's service, only in the packaged Plinth app.
    let legacyService: String?
    let backend: KeychainBackend
    let tombstones: KeychainTombstones

    /// The store the app uses for `account`.
    static func standard(account: String) -> KeychainItemStore {
        let identity = runningAppIdentity
        return KeychainItemStore(account: account,
                                 service: identity == .legacy ? legacyKeychainService : plinthKeychainService,
                                 legacyService: identity == .plinth ? legacyKeychainService : nil,
                                 backend: SystemKeychainBackend(), tombstones: DefaultsKeychainTombstones())
    }

    /// The saved value. Throws `APIError.keychain` for any Keychain failure (a refused, cancelled or locked read of
    /// either service), leaving nothing marked, so the next read tries again.
    func load() throws -> KeychainValue {
        switch backend.read(service: service, account: account) {
        case .found(let data): return .data(data)
        case .unreadableValue: return .unreadable
        case .failed(let status): throw APIError.keychain(status)
        case .notFound: break
        }
        guard let legacyService, !tombstones.contains(account) else { return .none }
        switch backend.read(service: legacyService, account: account) {
        case .notFound:
            tombstones.insert(account)
            return .none
        case .failed(let status): throw APIError.keychain(status)
        case .unreadableValue: return .unreadable
        case .found(let old):
            let added = backend.add(service: service, account: account, data: old)
            if added == errSecDuplicateItem {
                // Added meanwhile: the new item wins.
                if case .found(let current) = backend.read(service: service, account: account) {
                    tombstones.insert(account)
                    return .data(current)
                }
                return .data(old)
            }
            guard added == errSecSuccess else { return .data(old) }
            if case .found(let readBack) = backend.read(service: service, account: account), readBack == old {
                tombstones.insert(account)
            } else {
                _ = backend.delete(service: service, account: account)
            }
            return .data(old)
        }
    }

    func save(_ data: Data) throws {
        var status = backend.update(service: service, account: account, data: data)
        if status == errSecItemNotFound { status = backend.add(service: service, account: account, data: data) }
        guard status == errSecSuccess else { throw APIError.keychain(status) }
        if legacyService != nil { tombstones.insert(account) }
    }

    /// Removes the key. Slant Studio's item is also removed where the Keychain allows it (a refusal is ignored), and
    /// the account is marked first, so the old key is never brought back.
    func delete() throws {
        if let legacyService {
            tombstones.insert(account)
            _ = backend.delete(service: legacyService, account: account)
        }
        let status = backend.delete(service: service, account: account)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw APIError.keychain(status) }
    }
}

// MARK: Notice

enum LegacyMigrationNoticeKind: Equatable, Identifiable {
    case slantStudioOpen
    case folderNotMoved
    case libraryKeptSeparate
    case notificationsOff
    var id: Self { self }
}

/// The notices to show at the top of the main window, the both-apps-open warning first. Nothing at all when everything
/// moved and Slant Studio isn't running.
func legacyMigrationNotices(copyFailedThisLaunch: Bool, folderNoticeDismissed: Bool, notificationsWereOn: Bool,
                            notificationsOnNow: Bool, orderWatchEnabled: Bool, slantStudioOpen: Bool = false,
                            libraryKeptSeparate: Bool = false,
                            libraryNoticeDismissed: Bool = false) -> [LegacyMigrationNoticeKind] {
    var notices: [LegacyMigrationNoticeKind] = []
    if slantStudioOpen { notices.append(.slantStudioOpen) }
    if copyFailedThisLaunch, !folderNoticeDismissed { notices.append(.folderNotMoved) }
    if libraryKeptSeparate, !libraryNoticeDismissed { notices.append(.libraryKeptSeparate) }
    if notificationsWereOn, !notificationsOnNow, orderWatchEnabled { notices.append(.notificationsOff) }
    return notices
}

/// Whether another app with Slant Studio's bundle ID is running alongside this one. `endedPID` is an app that has just
/// quit (it may still be listed). A build running as Slant Studio itself never shows the notice.
func slantStudioRunsAlongside(runningLegacyPIDs: [pid_t], ownPID: pid_t, endedPID: pid_t? = nil,
                              identity: AppIdentity) -> Bool {
    guard identity != .legacy else { return false }
    return runningLegacyPIDs.contains { $0 != ownPID && $0 != endedPID }
}

/// Whether the saved "notifications were on" flag has served its purpose and can go: notifications are on again, or
/// order checks are off, so there is nothing to turn on.
func legacyNotifyFlagIsSpent(notificationsOnNow: Bool, orderWatchEnabled: Bool) -> Bool {
    notificationsOnNow || !orderWatchEnabled
}

/// Activity title for the one-time move. The old name is allowed in this file only (AppNameCopyTests).
let legacyMigrationActivityTitle = "Moved from Slant Studio"
let legacyFolderNotMovedNoticeText = "Plinth couldn’t copy your Slant Studio library this time, so it is using it where it is. It will try again the next time it opens. Nothing was deleted."
let legacyLibraryKeptSeparateNoticeText = "Plinth already had its own library, so it didn’t bring over Slant Studio’s. Slant Studio’s library is still in its own folder; nothing was deleted."
let legacyLibraryKeptSeparateActivityTitle = "Kept Plinth’s own library"
let legacyLibraryKeptSeparateActivityDetail = "Slant Studio’s library was left in its own folder. Nothing was deleted."
let legacySlantStudioOpenNoticeText = "Slant Studio is open too. Quit it while you use Plinth: the two apps don’t share their payment and draft safeguards."
let legacyNotificationsOffNoticeText = "Order notifications are off for now: macOS treats Plinth as a new app, so it needs your permission again."

@MainActor final class LegacyMigrationNoticeState: ObservableObject {
    static let shared = LegacyMigrationNoticeState()
    @Published private(set) var folderNoticeDismissed = false
    @Published private(set) var libraryNoticeDismissed = false
    @Published private(set) var notificationsWereOn = UserDefaults.standard.bool(forKey: LegacyMigrationKeys.notifyWasOn)
    /// Another app with Slant Studio's bundle ID is running. Read from NSWorkspace only once watching starts (at launch).
    @Published private(set) var slantStudioOpen = false
    /// Launch and quit observers, added once and kept for the app's lifetime (this object is never released).
    private var workspaceObservers: [NSObjectProtocol] = []

    func dismissFolderNotice() { folderNoticeDismissed = true }

    /// The seller accepts Plinth's own library: the folder marker is written, so neither the notice nor the check comes
    /// back. Slant Studio's folder is left as it is.
    func dismissLibraryNotice() {
        libraryNoticeDismissed = true
        UserDefaults.standard.set(true, forKey: LegacyMigrationKeys.supportFolder)
    }

    /// Starts following Slant Studio's launches and quits. Read-only: it never blocks, asks or sends anything.
    func startWatchingForSlantStudio() {
        guard workspaceObservers.isEmpty, runningAppIdentity != .legacy else { return }
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            let observer = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                guard app?.bundleIdentifier == legacyAppBundleIdentifier else { return }
                let ended = notification.name == NSWorkspace.didTerminateApplicationNotification ? app?.processIdentifier : nil
                MainActor.assumeIsolated { self?.refreshSlantStudioOpen(endedPID: ended) }
            }
            workspaceObservers.append(observer)
        }
        refreshSlantStudioOpen(endedPID: nil)
    }

    private func refreshSlantStudioOpen(endedPID: pid_t?) {
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: legacyAppBundleIdentifier)
            .filter { !$0.isTerminated }
            .map(\.processIdentifier)
        let open = slantStudioRunsAlongside(runningLegacyPIDs: running, ownPID: ProcessInfo.processInfo.processIdentifier,
                                            endedPID: endedPID, identity: runningAppIdentity)
        if open != slantStudioOpen { slantStudioOpen = open }
    }

    func clearNotificationsFlag() {
        notificationsWereOn = false
        UserDefaults.standard.removeObject(forKey: LegacyMigrationKeys.notifyWasOn)
    }
}

/// Shown at the top of the main window only when something from Slant Studio needs the seller's attention, or while
/// Slant Studio runs alongside Plinth. No button is the default, so Return does nothing.
struct LegacyMigrationNoticeView: View {
    @ObservedObject private var state = LegacyMigrationNoticeState.shared
    @ObservedObject private var orderWatch = OrderWatch.shared

    private var notices: [LegacyMigrationNoticeKind] {
        legacyMigrationNotices(copyFailedThisLaunch: AppSupportLocation.copyFailedThisLaunch,
                               folderNoticeDismissed: state.folderNoticeDismissed,
                               notificationsWereOn: state.notificationsWereOn,
                               notificationsOnNow: orderWatch.notify, orderWatchEnabled: orderWatch.enabled,
                               slantStudioOpen: state.slantStudioOpen,
                               libraryKeptSeparate: AppSupportLocation.libraryKeptSeparateThisLaunch,
                               libraryNoticeDismissed: state.libraryNoticeDismissed)
    }

    var body: some View {
        let shown = notices
        VStack(spacing: 8) {
            ForEach(shown) { notice in
                switch notice {
                case .slantStudioOpen:
                    row(legacySlantStudioOpenNoticeText, symbol: "exclamationmark.triangle") { EmptyView() }
                case .folderNotMoved:
                    row(legacyFolderNotMovedNoticeText, symbol: "exclamationmark.triangle") {
                        Button("Dismiss") { state.dismissFolderNotice() }
                    }
                case .libraryKeptSeparate:
                    row(legacyLibraryKeptSeparateNoticeText, symbol: "info.circle") {
                        Button("Dismiss") { state.dismissLibraryNotice() }
                    }
                case .notificationsOff:
                    row(legacyNotificationsOffNoticeText, symbol: "bell.slash") {
                        Button("Turn On Notifications…") {
                            state.clearNotificationsFlag()
                            orderWatch.setNotify(true)
                        }
                        Button("Dismiss") { state.clearNotificationsFlag() }
                    }
                }
            }
        }
        .padding(.horizontal, shown.isEmpty ? 0 : 12)
        .padding(.top, shown.isEmpty ? 0 : 8)
        .onAppear {
            clearSpentFlag()
            state.startWatchingForSlantStudio()
        }
        .onChange(of: orderWatch.notify) { _, _ in clearSpentFlag() }
        .onChange(of: orderWatch.enabled) { _, _ in clearSpentFlag() }
    }

    private func clearSpentFlag() {
        if state.notificationsWereOn,
           legacyNotifyFlagIsSpent(notificationsOnNow: orderWatch.notify, orderWatchEnabled: orderWatch.enabled) {
            state.clearNotificationsFlag()
        }
    }

    private func row<Buttons: View>(_ text: String, symbol: String, @ViewBuilder buttons: () -> Buttons) -> some View {
        HStack(spacing: 10) {
            Label(text, systemImage: symbol)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            buttons()
        }
        .padding(10)
        .background(Color.studioCard, in: RoundedRectangle(cornerRadius: StudioMetrics.cardRadius))
        .overlay(RoundedRectangle(cornerRadius: StudioMetrics.cardRadius).stroke(Color.studioHairline))
    }
}
