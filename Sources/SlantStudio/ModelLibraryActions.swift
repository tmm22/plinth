import SwiftUI
import AppKit
import UniformTypeIdentifiers
import simd

// MARK: - Rename

/// Library names become the Slant upload name, so keep them short and free of path separators.
let maximumModelNameLength = 100

/// Why a proposed library name can't be used, or nil when it's acceptable.
func modelNameProblem(_ proposed: String) -> String? {
    let trimmed = proposed.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty { return "Enter a name." }
    if trimmed.count > maximumModelNameLength { return "Names can be at most \(maximumModelNameLength) characters." }
    if trimmed.contains("/") || trimmed.contains(":") { return "Names can’t contain “/” or “:”." }
    if trimmed.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) || CharacterSet.newlines.contains($0) }) {
        return "Names can’t contain line breaks or control characters."
    }
    return nil
}

/// The trimmed name to store, or nil when it isn't valid.
func validatedModelName(_ proposed: String) -> String? {
    modelNameProblem(proposed) == nil ? proposed.trimmingCharacters(in: .whitespacesAndNewlines) : nil
}

func renameUploadedNote(isUploaded: Bool) -> String? {
    isUploaded
        ? "Slant can’t rename an uploaded file, so the copy in your Slant account keeps its original name. A later upload uses the new name."
        : nil
}

// MARK: - Export

/// Default file name for an exported copy: the library name with characters Finder rejects replaced.
func exportFileName(modelName: String, fileExtension: String) -> String {
    var base = modelName.unicodeScalars.map { scalar -> String in
        if scalar == "/" || scalar == ":" || CharacterSet.controlCharacters.contains(scalar) || CharacterSet.newlines.contains(scalar) { return "-" }
        return String(scalar)
    }.joined().trimmingCharacters(in: .whitespacesAndNewlines)
    while base.hasPrefix(".") { base.removeFirst() }
    base = base.trimmingCharacters(in: .whitespacesAndNewlines)
    if base.isEmpty { base = "Model" }
    if base.count > 200 { base = String(base.prefix(200)) }
    let ext = fileExtension.lowercased()
    return ext.isEmpty ? base : "\(base).\(ext)"
}

func missingLibraryFileMessage(name: String) -> String {
    "The library file for “\(name)” is missing. Remove it from the library and import the model again."
}

/// Refuses destinations that would overwrite the library copy or any file in Slant Studio's support folder.
func exportDestinationProblem(source: URL, destination: URL, supportDirectory: URL) -> String? {
    let from = source.standardizedFileURL.resolvingSymlinksInPath().path
    let to = destination.standardizedFileURL.resolvingSymlinksInPath().path
    let support = supportDirectory.standardizedFileURL.resolvingSymlinksInPath().path
    if from == to || to == support || to.hasPrefix(support + "/") {
        return "Choose a folder outside Slant Studio’s library, such as Documents or Desktop."
    }
    return nil
}

/// Copies (never moves) a model file. An existing destination is only replaced after the copy succeeds.
func exportModelFile(from source: URL, to destination: URL) throws {
    let manager = FileManager.default
    let staging = destination.deletingLastPathComponent()
        .appendingPathComponent(".\(UUID().uuidString)-\(destination.lastPathComponent)")
    try manager.copyItem(at: source, to: staging)
    do {
        if manager.fileExists(atPath: destination.path) {
            _ = try manager.replaceItemAt(destination, withItemAt: staging)
        } else {
            try manager.moveItem(at: staging, to: destination)
        }
    } catch {
        try? manager.removeItem(at: staging)
        throw error
    }
}

// MARK: - Local and cloud links

/// The library model linked to an uploaded Slant file, most recently added first.
func localModel(linkedTo remoteID: String, in models: [LocalModel]) -> LocalModel? {
    guard !remoteID.isEmpty else { return nil }
    return models.first { $0.remoteID == remoteID }
}

func reuploadConfirmationMessage(name: String) -> String {
    "This uploads “\(name)” as a second file in your Slant account. The file already uploaded is not replaced or deleted, and existing orders keep using it. This Mac’s copy will link to the new file."
}

// MARK: - Prepared material

struct PreparedMaterialMismatch: Equatable {
    let filamentID: String
    /// Nil when the saved material is not in the current catalogue.
    let name: String?
    let available: Bool?
    var canApply: Bool { name != nil && available != false }
}

/// Compares a prepared copy's saved material with the current choice. Returns nil when they match,
/// when no material was saved, or while the material list hasn't loaded.
func preparedMaterialMismatch(recipeFilamentID: String?, selectedFilamentID: String, filaments: [Record]) -> PreparedMaterialMismatch? {
    guard let saved = recipeFilamentID?.trimmingCharacters(in: .whitespacesAndNewlines), !saved.isEmpty,
          saved != selectedFilamentID, !filaments.isEmpty else { return nil }
    guard let record = filaments.first(where: { $0.id == saved }) else {
        return PreparedMaterialMismatch(filamentID: saved, name: nil, available: nil)
    }
    return PreparedMaterialMismatch(filamentID: saved, name: displayName(for: record, fallback: "Untitled material"),
                                    available: filamentAvailability(record))
}

func preparedMaterialMismatchMessage(_ mismatch: PreparedMaterialMismatch) -> String {
    guard let name = mismatch.name else {
        return "The material saved with this prepared copy is no longer listed. Estimates and orders use the material selected here."
    }
    if mismatch.available == false {
        return "This copy was prepared for \(name), which is currently out of stock. Estimates and orders use the material selected here."
    }
    return "This copy was prepared for \(name). Estimates and orders use the material selected here."
}

// MARK: - Scale check

let scaleWarningSmallestLargestMM: Float = 3

struct ScaleSuggestion: Equatable, Identifiable {
    let factor: Double
    let unit: String
    let resultLargestMM: Float
    var id: Double { factor }
    var factorLabel: String { String(format: "%g", factor) }
    var title: String { "Save Copy ×\(factorLabel) (\(unit) → \(String(format: "%.1f", resultLargestMM)) mm)" }
}

struct ScaleWarning: Equatable {
    let largestMM: Float
    let suggestions: [ScaleSuggestion]
    /// The unitless format the model was read from (STL or OBJ).
    var formatName = "STL"
    var message: String {
        let size = String(format: "%.2f", largestMM)
        return "The largest dimension is \(size) mm. \(formatName) files don’t record units and Slant reads them as millimetres, so this would print at \(size) mm. It may have been exported in inches, centimetres or metres."
    }
}

/// Flags tiny bounding boxes that suggest an export in a larger unit. Oversized models are flagged by the preview's
/// build-volume warning instead. Suggestions only cover sizes that fit Slant's build volume. Never changes geometry.
func scaleWarning(extentMM: SIMD3<Float>) -> ScaleWarning? {
    let largest = max(extentMM.x, extentMM.y, extentMM.z)
    guard largest.isFinite, largest > 0, largest < scaleWarningSmallestLargestMM else { return nil }
    let candidates: [(Double, String)] = [(25.4, "inches"), (10, "centimetres"), (1000, "metres")]
    let suggestions = candidates.compactMap { factor, unit -> ScaleSuggestion? in
        let result = largest * Float(factor)
        guard result >= scaleWarningSmallestLargestMM, result <= slantBuildVolumeMM else { return nil }
        return ScaleSuggestion(factor: factor, unit: unit, resultLargestMM: result)
    }
    return ScaleWarning(largestMM: largest, suggestions: suggestions)
}

/// Scaled copies are only offered for plain imports, whose records don't carry dimension-dependent data. The copy is
/// always a binary STL, so an OBJ or 3MF original is kept as it is.
func canSaveScaledCopy(_ model: LocalModel) -> Bool {
    model.supportsMeshPreview && model.printRecipe == nil && model.designImprovement == nil
        && model.reinforcement == nil && model.autoImprovement == nil
}

/// Model file extensions dropped from a library name before a suffix is added, so "bracket.stl" doesn't become
/// "bracket.stl-scaled-x25.4".
let modelNameFileExtensions: Set<String> = ["stl", "obj", "3mf"]

func scaledCopyName(_ name: String, factor: Double) -> String {
    var base = name
    if let dot = base.lastIndex(of: "."), dot > base.startIndex,
       modelNameFileExtensions.contains(base[base.index(after: dot)...].lowercased()) {
        base = String(base[..<dot])
    }
    return "\(base)-scaled-x\(String(format: "%g", factor))"
}

enum ScaledCopyError: LocalizedError {
    case invalidFactor, changedTopology, collapsedTriangles, unexpectedSize
    var errorDescription: String? {
        switch self {
        case .invalidFactor: return "Choose a positive scale factor."
        case .changedTopology: return "The scaled copy didn’t keep every triangle, so it wasn’t saved."
        case .collapsedTriangles: return "Scaling would collapse some triangles, so the copy wasn’t saved. Scale the model in your CAD tool or slicer instead."
        case .unexpectedSize: return "The scaled copy didn’t come out at the expected size, so it wasn’t saved."
        }
    }
}

private func degenerateTriangleCount(_ mesh: STLMesh) -> Int {
    var count = 0
    for i in stride(from: 0, to: mesh.vertices.count, by: 9) {
        let a = SIMD3(mesh.vertices[i], mesh.vertices[i + 1], mesh.vertices[i + 2])
        let b = SIMD3(mesh.vertices[i + 3], mesh.vertices[i + 4], mesh.vertices[i + 5])
        let c = SIMD3(mesh.vertices[i + 6], mesh.vertices[i + 7], mesh.vertices[i + 8])
        if simd_length_squared(simd_cross(b - a, c - a)) == 0 { count += 1 }
    }
    return count
}

extension STLMesh {
    /// A uniformly scaled binary STL, parsed back and checked before it is returned.
    func scaledSTLData(by factor: Double) throws -> Data {
        guard factor.isFinite, factor > 0 else { throw ScaledCopyError.invalidFactor }
        let f = Float(factor)
        let scaled = STLMesh(vertices: vertices.map { $0 * f }, minimum: minimum * f, maximum: maximum * f)
        let data = scaled.binarySTL()
        let parsed = try STLMesh.parse(data)
        guard parsed.triangleCount == triangleCount else { throw ScaledCopyError.changedTopology }
        guard degenerateTriangleCount(parsed) <= degenerateTriangleCount(self) else { throw ScaledCopyError.collapsedTriangles }
        let expected = (maximum - minimum) * f
        let actual = parsed.maximum - parsed.minimum
        for axis in 0..<3 where abs(actual[axis] - expected[axis]) > max(expected[axis], 1) * 0.0001 {
            throw ScaledCopyError.unexpectedSize
        }
        return data
    }
}

// MARK: - Menus

/// Destinations listed in the Go menu, in sidebar order. Developer destinations appear only when developer tools are on.
func goMenuDestinations(showDeveloperTools: Bool) -> [Destination] {
    sidebarDestinations(showDeveloperTools: showDeveloperTools)
}

/// ⌘1 Models, ⌘2 Orders, ⌘3 Catalog; the Go menu owns them. Developer destinations have no shortcut, so the numbers
/// never shift when developer tools are switched on or off.
func goMenuShortcut(for destination: Destination) -> Character? {
    guard let index = sidebarPrimaryDestinations.firstIndex(of: destination), index < 9 else { return nil }
    return Character("\(index + 1)")
}

/// A snapshot of AppKit's modal state. With a sheet up the key window is the sheet itself, so checking only the key
/// window's `attachedSheet` misses SwiftUI sheets, alerts and confirmation dialogs.
struct AppModalState: Equatable {
    var hasModalWindow = false
    var keyWindowIsSheet = false
    var anyWindowHasSheet = false
    var isPresenting: Bool { hasModalWindow || keyWindowIsSheet || anyWindowHasSheet }

    @MainActor static var current: AppModalState {
        let key = NSApp.keyWindow
        return AppModalState(
            hasModalWindow: NSApp.modalWindow != nil,
            keyWindowIsSheet: key.map { $0.isSheet || $0.sheetParent != nil } ?? false,
            anyWindowHasSheet: NSApp.windows.contains { $0.attachedSheet != nil || $0.sheetParent != nil }
        )
    }
}

/// True while any sheet, alert, confirmation dialog or modal panel is up. Menu commands stay reachable then, unlike
/// in-window controls, so the Go and model-file commands refuse to act (for example, ⌘1 during a Pay review).
@MainActor func appIsPresentingModalUI() -> Bool {
    AppModalState.current.isPresenting
}

/// Publishes `appIsPresentingModalUI()` so menu items can show as disabled. The action-time check is authoritative.
@MainActor final class ModalPresentationMonitor: ObservableObject {
    @Published private(set) var isPresenting = false
    private var observers: [NSObjectProtocol] = []

    init() {
        let names: [Notification.Name] = [
            NSWindow.willBeginSheetNotification, NSWindow.didEndSheetNotification,
            NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
            NSApplication.didUpdateNotification
        ]
        observers = names.map { name in
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.update() }
            }
        }
    }

    deinit { observers.forEach(NotificationCenter.default.removeObserver) }

    func update() {
        let presenting = appIsPresentingModalUI()
        if presenting != isPresenting { isPresenting = presenting }
    }
}

/// The rename sheet only shows while its model exists; a stale ID must not count as a presented sheet.
func renameSheetIsShown(renamingModelID: UUID?, models: [LocalModel]) -> Bool {
    guard let renamingModelID else { return false }
    return models.contains { $0.id == renamingModelID }
}

/// Rename… and Export… in the File menu act on the selected local model on the Models screen, never over a sheet.
func modelFileCommandsEnabled(destination: Destination, hasSelectedLocal: Bool, sheetPresented: Bool) -> Bool {
    destination == .models && hasSelectedLocal && !sheetPresented
}

// MARK: - Store actions

extension StudioStore {
    /// Sheets the store itself drives. A rename only counts while its model still exists, so a stale ID can't block menus.
    var isPresentingSheet: Bool {
        showOrderComposer || showPlatformComposer || showSettingsPlatformComposer || showImportFromURL || showSavedProducts
            || showOrderImport || showShopFollowUp || batchPayRequest != nil
            || listingImagesModelID != nil || showSpendingReport
            || personalisationTemplate != nil || meshFitRequest != nil
            || renameSheetIsShown(renamingModelID: renamingModelID, models: localModels)
    }

    /// Menu-driven Rename…: only from Models with a local model selected and nothing else presented, so the ID is
    /// never left set without a visible sheet.
    func beginRenamingSelectedModelFromMenu() {
        guard modelFileCommandsEnabled(destination: destination, hasSelectedLocal: selectedLocal != nil,
                                       sheetPresented: isPresentingSheet || appIsPresentingModalUI()),
              let id = selectedLocalID else { return }
        renamingModelID = id
    }

    func exportSelectedModelFromMenu() {
        guard modelFileCommandsEnabled(destination: destination, hasSelectedLocal: selectedLocal != nil,
                                       sheetPresented: isPresentingSheet || appIsPresentingModalUI()),
              let id = selectedLocalID else { return }
        exportLocalModel(id: id)
    }

    func goFromMenu(to item: Destination) {
        guard !isPresentingSheet, !appIsPresentingModalUI(),
              goMenuDestinations(showDeveloperTools: showDeveloperTools).contains(item) else { return }
        destination = item
    }

    @discardableResult
    func renameLocalModel(id: UUID, name: String) -> Bool {
        guard let index = localModels.firstIndex(where: { $0.id == id }) else { return false }
        guard let validated = validatedModelName(name) else {
            showError(modelNameProblem(name) ?? "Enter a name.")
            return false
        }
        let previous = localModels[index].name
        guard validated != previous else { return true }
        localModels[index].name = validated
        saveModels()
        activities.insert(Activity(title: "Rename model", detail: "\(previous) → \(validated)", success: true), at: 0)
        return true
    }

    /// Saves a copy of the library file wherever the user chooses. The library copy is never moved.
    func exportLocalModel(id: UUID) {
        guard let model = localModels.first(where: { $0.id == id }) else { return }
        let source = model.url
        guard FileManager.default.fileExists(atPath: source.path) else {
            showError(missingLibraryFileMessage(name: model.name))
            return
        }
        let ext = source.pathExtension
        let panel = NSSavePanel()
        panel.title = "Export Model"
        panel.nameFieldStringValue = exportFileName(modelName: model.name, fileExtension: ext)
        if let type = UTType(filenameExtension: ext) { panel.allowedContentTypes = [type] }
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        if let problem = exportDestinationProblem(source: source, destination: destination, supportDirectory: Self.supportDirectory) {
            showError(problem)
            return
        }
        do {
            try exportModelFile(from: source, to: destination)
            activities.insert(Activity(title: "Export model", detail: model.name, success: true), at: 0)
        } catch {
            showError("Could not export “\(model.name)”: \(error.localizedDescription)")
        }
    }
}

// MARK: - Rename sheet

struct RenameModelSheet: View {
    @EnvironmentObject var store: StudioStore
    @Environment(\.dismiss) private var dismiss
    let model: LocalModel
    @State private var name = ""

    var body: some View {
        let problem = modelNameProblem(name)
        VStack(alignment: .leading, spacing: 14) {
            Text("Rename Model").font(.title3.weight(.semibold))
            TextField("Model name", text: $name)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Model name")
            if let problem, !name.isEmpty {
                Label(problem, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.orange)
            }
            if let note = renameUploadedNote(isUploaded: model.remoteID != nil) {
                Text(note).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Rename", action: save)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(problem != nil)
            }
        }
        .padding(24)
        .frame(width: 420)
        .onAppear { name = model.name }
    }

    private func save() {
        guard modelNameProblem(name) == nil else { return }
        if store.renameLocalModel(id: model.id, name: name) { dismiss() }
    }
}
