import SwiftUI
import AppKit
import simd

// Listing assets for a library model: square PNG renders for marketplace listings, and a plain-text block of the
// model's size, material and weight with suggested production-partner wording. Both are local only: nothing is sent
// to Slant, and nothing about the model or its listing is saved beyond the image files the user asks for.

// MARK: - Views and cameras

/// Edge length of an exported listing image. Etsy recommends at least 2000 px on the shortest side for zoom.
let listingImagePixelSize = 2000

/// Pixel tests allowed per listing image (2000 px, sampled at 4000 × 4000): about 50 times the sample grid. Real
/// models stay far below this; a mesh of huge overlapping triangles is refused for that view instead of taking minutes.
let listingImageRasterBudget = 800_000_000

enum ListingImageAngle: String, CaseIterable, Identifiable, Sendable {
    case threeQuarter, front, side, back, top, rearThreeQuarter

    var id: String { rawValue }

    var title: String {
        switch self {
        case .threeQuarter: "Three-quarter"
        case .front: "Front"
        case .side: "Side"
        case .back: "Back"
        case .top: "Top"
        case .rearThreeQuarter: "Rear three-quarter"
        }
    }

    /// Lower-case name used in the file name, e.g. "Desk Tidy – front.png".
    var fileSuffix: String { title.lowercased() }

    /// Selected when the sheet opens: the views most listings lead with.
    var selectedByDefault: Bool { [.threeQuarter, .front, .side, .top].contains(self) }

    /// Direction towards the viewer in preview scene space (scene = (x, z, −y) of the STL, so STL front −Y is scene +Z).
    var eye: SIMD3<Float> {
        switch self {
        case .threeQuarter: SIMD3(11, 8, 12)        // the preview's default: front right, from above
        case .front: SIMD3(0, 0, 1)                 // STL −Y
        case .side: SIMD3(1, 0, 0)                  // STL +X, the right-hand side
        case .back: SIMD3(0, 0, -1)                 // STL +Y
        case .top: SIMD3(0, 1, 0)                   // STL +Z, looking down
        case .rearThreeQuarter: SIMD3(-11, 8, -12)  // back left, from above
        }
    }

    /// Looking straight down, the model's back points up the image so the front stays nearest the viewer.
    var upHint: SIMD3<Float> { self == .top ? SIMD3(0, 0, -1) : SIMD3(0, 1, 0) }
}

/// The orthographic camera for a listing view. Every case has a valid camera.
func listingCamera(_ angle: ListingImageAngle) -> MeshRenderCamera {
    MeshRenderCamera(eye: angle.eye, upHint: angle.upHint) ?? .thumbnail
}

/// A key light above and slightly left of the camera, so every view is lit from the viewer's side.
func listingLight(_ camera: MeshRenderCamera) -> SIMD3<Float> {
    simd_normalize(camera.eye + camera.up * 0.75 - camera.right * 0.3)
}

// MARK: - Colour

/// The preview's neutral grey-blue, used when no material is chosen or its colour can't be read.
let listingNeutralColour = SIMD3<Float>(0.72, 0.79, 0.84)

/// Parses a material's `hexValue`: "#RGB", "#RRGGBB" or "#RRGGBBAA" (alpha ignored), with or without "#" or "0x".
/// Nil for anything else, so callers fall back to the neutral colour instead of showing a wrong one.
func listingColour(hex: String) -> SIMD3<Float>? {
    var text = hex.trimmingCharacters(in: .whitespacesAndNewlines)
    if text.hasPrefix("#") { text.removeFirst() } else if text.lowercased().hasPrefix("0x") { text.removeFirst(2) }
    guard text.allSatisfy(\.isHexDigit) else { return nil }
    if text.count == 3 { text = text.map { "\($0)\($0)" }.joined() }
    if text.count == 8 { text = String(text.prefix(6)) }
    guard text.count == 6, let number = UInt32(text, radix: 16) else { return nil }
    return SIMD3(Float((number >> 16) & 255) / 255, Float((number >> 8) & 255) / 255, Float(number & 255) / 255)
}

/// Lighting for a listing render in this colour. Very dark colours are lifted a little and get a stronger sheen so
/// black filament still shows its shape; very light ones are capped so a white model doesn't vanish into the background.
func listingRenderStyle(colour: SIMD3<Float>, camera: MeshRenderCamera) -> MeshRenderStyle {
    let base = simd_clamp(colour, SIMD3<Float>(repeating: 0.22), SIMD3<Float>(repeating: 0.9))
    let luminance = simd_dot(base, SIMD3<Float>(0.2126, 0.7152, 0.0722))
    return MeshRenderStyle(base: base, light: listingLight(camera), ambient: 0.32, diffuse: 0.68,
                           sheen: 0.02 + 0.3 * (1 - luminance), fill: 0.8)
}

enum ListingBackground: String, CaseIterable, Identifiable, Sendable {
    case white, lightGrey
    var id: String { rawValue }
    var title: String { self == .white ? "White" : "Light Grey" }
    var colour: SIMD3<Float> { self == .white ? SIMD3(1, 1, 1) : SIMD3(0.94, 0.94, 0.95) }
}

/// Lays premultiplied RGBA over an opaque background colour; the result is fully opaque.
func listingComposite(_ rgba: [UInt8], over background: SIMD3<Float>) -> [UInt8] {
    var out = rgba
    let bg = simd_clamp(background, SIMD3<Float>(repeating: 0), SIMD3<Float>(repeating: 1)) * 255
    for index in stride(from: 0, to: out.count - 3, by: 4) {
        let remaining = Float(255 - Int(rgba[index + 3])) / 255
        out[index] = UInt8(min(255, (Float(rgba[index]) + bg.x * remaining).rounded()))
        out[index + 1] = UInt8(min(255, (Float(rgba[index + 1]) + bg.y * remaining).rounded()))
        out[index + 2] = UInt8(min(255, (Float(rgba[index + 2]) + bg.z * remaining).rounded()))
        out[index + 3] = 255
    }
    return out
}

// MARK: - Rendering and files

enum ListingImageOutcome: Equatable {
    case png(Data)
    /// The mesh would need more pixel tests than `listingImageRasterBudget`, or rendered nothing.
    case tooComplex
    case cancelled
}

/// Renders one listing view as an opaque PNG. Pure CPU work, safe on any thread.
func renderListingImagePNG(_ mesh: STLMesh, angle: ListingImageAngle, colour: SIMD3<Float>, background: ListingBackground,
                           size: Int = listingImagePixelSize, rasterBudget: Int = listingImageRasterBudget,
                           isCancelled: () -> Bool = { false }) -> ListingImageOutcome {
    let camera = listingCamera(angle)
    let style = listingRenderStyle(colour: colour, camera: camera)
    guard let rgba = renderMeshRGBA(mesh, size: size, camera: camera, style: style, rasterBudget: rasterBudget,
                                    isCancelled: isCancelled) else {
        return isCancelled() ? .cancelled : .tooComplex
    }
    if isCancelled() { return .cancelled }
    guard let png = thumbnailPNGData(rgba: listingComposite(rgba, over: background.colour), size: size) else { return .tooComplex }
    return .png(png)
}

/// "Desk Tidy – front.png", then "Desk Tidy – front 2.png" and so on for later attempts. The model name is made safe
/// for a file name first, so a long name never cuts off the view.
func listingImageFileName(modelName: String, angle: ListingImageAngle, attempt: Int = 1) -> String {
    let base = exportFileName(modelName: modelName, fileExtension: "")
    let number = attempt > 1 ? " \(attempt)" : ""
    return "\(base) – \(angle.fileSuffix)\(number).png"
}

struct ListingImageExportSummary: Equatable {
    var saved: [URL] = []
    var failures: [String] = []
    var cancelled = false
    /// Set when the model couldn't be read at all; nothing else was attempted.
    var readFailure: String?
}

/// Reads the model once, then renders and saves each chosen view in order, one at a time. Existing files are never
/// replaced: a taken name gets the next number. Stops between views (and inside a render) once `isCancelled` is true.
func exportListingImages(modelURL: URL, modelName: String, angles: [ListingImageAngle], colour: SIMD3<Float>,
                         background: ListingBackground, folder: URL, size: Int = listingImagePixelSize,
                         rasterBudget: Int = listingImageRasterBudget, isCancelled: () -> Bool,
                         progress: (Int, ListingImageAngle) -> Void = { _, _ in }) -> ListingImageExportSummary {
    var summary = ListingImageExportSummary()
    let mesh: STLMesh
    do {
        mesh = try loadPreviewModel(from: modelURL).mesh
    } catch {
        summary.readFailure = error.localizedDescription
        return summary
    }
    let access = folder.startAccessingSecurityScopedResource()
    defer { if access { folder.stopAccessingSecurityScopedResource() } }
    for (index, angle) in angles.enumerated() {
        if isCancelled() { summary.cancelled = true; break }
        progress(index, angle)
        switch renderListingImagePNG(mesh, angle: angle, colour: colour, background: background, size: size,
                                     rasterBudget: rasterBudget, isCancelled: isCancelled) {
        case .cancelled:
            summary.cancelled = true
        case .tooComplex:
            summary.failures.append("\(angle.title): too detailed to render at this size.")
        case .png(let data):
            var written: URL?
            var lastError: Error?
            for attempt in 1...500 {
                let url = folder.appendingPathComponent(listingImageFileName(modelName: modelName, angle: angle, attempt: attempt))
                if FileManager.default.fileExists(atPath: url.path) { continue }
                do {
                    try data.write(to: url, options: .withoutOverwriting)
                    written = url
                    break
                } catch {
                    lastError = error
                    // Another file may have taken the name just now; anything else won't fix itself.
                    if !FileManager.default.fileExists(atPath: url.path) { break }
                }
            }
            if let written { summary.saved.append(written) }
            else { summary.failures.append("\(angle.title): \(lastError?.localizedDescription ?? "no free file name in this folder").") }
        }
        if summary.cancelled { break }
    }
    return summary
}

func listingExportResultText(_ summary: ListingImageExportSummary) -> String {
    if let failure = summary.readFailure { return "No images were saved. \(failure)" }
    let saved = summary.saved.count == 1 ? "1 image" : "\(summary.saved.count) images"
    if summary.cancelled { return summary.saved.isEmpty ? "Stopped. No images were saved." : "Stopped after saving \(saved)." }
    return summary.saved.isEmpty ? "No images were saved." : "Saved \(saved)."
}

// MARK: - Listing details text

/// What the copied listing details are built from. Every part is optional; missing parts are left out, never guessed.
struct ListingDetailsFacts: Equatable {
    /// Overall bounding box in millimetres, as the preview reads the file.
    var extentMM: SIMD3<Float>?
    var objectCount = 1
    var materialName: String?
    /// Already formatted, e.g. "about 24 g (0.8 oz)".
    var weight: String?
}

/// Inches to two decimals, from millimetres (25.4 mm = 1 in).
func listingInches(_ mm: Float) -> String {
    String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), Double(mm) / 25.4)
}

/// "Size: 120.0 × 80.0 × 45.0 mm (4.72 × 3.15 × 1.77 in), width × depth × height". Nil without a usable extent.
func listingDimensionsLine(extentMM: SIMD3<Float>?, objectCount: Int = 1) -> String? {
    guard let extentMM else { return nil }
    let values = [extentMM.x, extentMM.y, extentMM.z]
    guard values.allSatisfy({ $0.isFinite && $0 >= 0 }), values.contains(where: { $0 > 0 }) else { return nil }
    let mm = values.map { String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), Double($0)) }.joined(separator: " × ")
    let inches = values.map(listingInches).joined(separator: " × ")
    let label = objectCount > 1 ? "Overall size (all \(objectCount) objects as placed)" : "Size"
    return "\(label): \(mm) mm (\(inches) in), width × depth × height"
}

/// Slant's model-analysis weight: whole grams (with ounces) when the unit is grams, otherwise the value as reported.
/// Nil when the metric is missing, not a positive number, or the analysis hasn't finished.
func listingWeight(metrics: [String: Any]) -> String? {
    let raw = metrics["weight"]
    let value: Double
    if let number = raw as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() { value = number.doubleValue }
    else if let text = raw as? String, let parsed = Double(text.trimmingCharacters(in: .whitespaces)) { value = parsed }
    else { return nil }
    guard value.isFinite, value > 0, value < 1_000_000 else { return nil }
    let unit = metricUnit("weight", metrics)
    switch unit.lowercased() {
    case "g", "gram", "grams":
        let ounces = String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), value / 28.349523125)
        return value < 1 ? "under 1 g" : "about \(Int(value.rounded())) g (\(ounces) oz)"
    case "kg":
        return "about " + String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), value) + " kg"
    default:
        let number = String(format: "%g", locale: Locale(identifier: "en_US_POSIX"), value)
        return unit.isEmpty ? "about \(number)" : "about \(number) \(unit)"
    }
}

/// Suggested production-partner wording; the seller should edit it to describe their own part in making the item.
let listingProductionPartnerSuggestion = "Made by: designed by [your shop] and 3D printed to order by our production partner, Slant 3D."
/// Said in the confirmation, not copied, so it can't end up in a listing by mistake.
let listingProductionPartnerNote = "The “Made by” line is suggested wording: edit it to describe your own role. On Etsy, also add Slant 3D as a production partner in your shop settings and choose it for this listing."

/// Plain text for a listing description, in a fixed order: size, material, weight, then the production-partner suggestion.
func listingDetailsText(_ facts: ListingDetailsFacts) -> String {
    var lines: [String] = []
    if let size = listingDimensionsLine(extentMM: facts.extentMM, objectCount: facts.objectCount) { lines.append(size) }
    if let material = facts.materialName?.trimmingCharacters(in: .whitespacesAndNewlines), !material.isEmpty {
        lines.append("Material: \(material)")
    }
    if let weight = facts.weight, !weight.isEmpty { lines.append("Weight: \(weight) (printed part, before packaging)") }
    var blocks: [String] = []
    if !lines.isEmpty { blocks.append(lines.joined(separator: "\n")) }
    blocks.append(listingProductionPartnerSuggestion)
    return blocks.joined(separator: "\n\n") + "\n"
}

/// The confirmation after copying, with what the seller should check, then the production-partner note.
func listingDetailsCopiedMessage(hasSize: Bool, scaleSuspect: Bool) -> String {
    let base: String
    if !hasSize { base = "Listing details copied, without the size: the model couldn’t be read." }
    else if scaleSuspect { base = "Listing details copied. Check the size: this model may not be in millimetres." }
    else { base = "Listing details copied." }
    return base + " " + listingProductionPartnerNote
}

/// The material line's name: print configuration's material belongs to the selected model, so another model's
/// details leave the material out rather than name one it may not be printed in. Shown as `materialDisplayName`.
func listingDetailsMaterialName(modelID: UUID, selectedModelID: UUID?, selectedMaterialName: String?) -> String? {
    guard modelID == selectedModelID, let name = selectedMaterialName?.trimmingCharacters(in: .whitespacesAndNewlines),
          !name.isEmpty else { return nil }
    return materialDisplayName(name)
}

/// Seconds a listing notice stays up: three, plus time to read a longer one (about 15 characters a second), at most 12.
func listingNoticeDuration(_ text: String) -> TimeInterval {
    min(12, max(3, Double(text.count) / 15))
}

// MARK: - Store actions

/// The brief "copied" confirmation shown over the Models screen. Memory only.
@MainActor final class ListingNotices: ObservableObject {
    static let shared = ListingNotices()
    @Published private(set) var message: String?
    private(set) var copying = false
    private var generation = 0

    func show(_ text: String) {
        generation += 1
        let current = generation
        message = text
        let seconds = listingNoticeDuration(text)
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            if generation == current { message = nil }
        }
    }

    fileprivate func setCopying(_ value: Bool) { copying = value }
}

extension StudioStore {
    /// The selected material's record, when one is chosen and loaded.
    var listingSelectedMaterial: Record? {
        filamentID.isEmpty ? nil : filaments.first { $0.id == filamentID }
    }

    /// Copies the model's listing details to the clipboard. Reads the library file off the main thread; nothing is sent.
    func copyListingDetails(for modelID: UUID) {
        let notices = ListingNotices.shared
        guard !notices.copying, let model = localModels.first(where: { $0.id == modelID }) else { return }
        notices.setCopying(true)
        let url = model.url
        let material = listingDetailsMaterialName(modelID: modelID, selectedModelID: selectedLocalID,
                                                  selectedMaterialName: listingSelectedMaterial.map { displayName(for: $0, fallback: "") })
        let metrics = model.remoteID.flatMap { id in files.first { $0.id == id } }?.metrics ?? [:]
        let weight = metricsAwaitingAnalysis(metrics) ? nil : listingWeight(metrics: metrics)
        Task { @MainActor in
            let preview = await Task.detached(priority: .userInitiated) { try? loadPreviewModel(from: url) }.value
            notices.setCopying(false)
            let extent = preview.map { $0.mesh.maximum - $0.mesh.minimum }
            let facts = ListingDetailsFacts(extentMM: extent, objectCount: preview?.objectCount ?? 1, materialName: material, weight: weight)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(listingDetailsText(facts), forType: .string)
            let suspect = extent.map { scaleWarning(extentMM: $0, fileExtension: url.pathExtension) != nil } ?? false
            notices.show(listingDetailsCopiedMessage(hasSize: listingDimensionsLine(extentMM: extent) != nil, scaleSuspect: suspect))
        }
    }

    /// Opens the Export Listing Images sheet for a previewable library model.
    func beginExportingListingImages(for modelID: UUID) {
        guard !isPresentingSheet, let model = localModels.first(where: { $0.id == modelID }), model.supportsMeshPreview else { return }
        listingImagesModelID = modelID
    }

    /// File › Export Listing Images…: Models only, with a local model selected and nothing modal shown.
    func exportListingImagesFromMenu() {
        guard modelFileCommandsEnabled(destination: destination, hasSelectedLocal: selectedLocal != nil,
                                       sheetPresented: menuCommandsBlockedByModalUI),
              let id = selectedLocalID else { return }
        beginExportingListingImages(for: id)
    }
}

// MARK: - Views

/// The "copied" confirmation, floating at the bottom of the Models screen for a few seconds.
struct ListingNoticeOverlay: ViewModifier {
    @ObservedObject private var notices = ListingNotices.shared

    func body(content: Content) -> some View {
        content.overlay(alignment: .bottom) {
            if let message = notices.message {
                Label(message, systemImage: "checkmark.circle.fill")
                    .font(.callout)
                    .frame(maxWidth: 480, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.studioHairline))
                    .padding(.bottom, 90)
                    .transition(.opacity)
                    .accessibilityAddTraits(.isStaticText)
                    .onAppear { NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                                                     userInfo: [.announcement: message, .priority: NSAccessibilityPriorityLevel.medium.rawValue]) }
            }
        }
        .animation(.easeInOut(duration: 0.2), value: notices.message)
    }
}

/// One listing-image export at a time for the sheet: renders off the main thread and publishes progress.
@MainActor final class ListingExportJob: ObservableObject {
    @Published private(set) var progress: (done: Int, total: Int, current: ListingImageAngle)?
    @Published private(set) var summary: ListingImageExportSummary?
    @Published private(set) var folder: URL?
    @Published private(set) var running = false
    private var task: Task<Void, Never>?

    func start(modelURL: URL, modelName: String, angles: [ListingImageAngle], colour: SIMD3<Float>,
               background: ListingBackground, folder destination: URL, onFinish: @escaping (ListingImageExportSummary) -> Void) {
        guard !running, let first = angles.first else { return }
        running = true
        folder = destination
        summary = nil
        progress = (0, angles.count, first)
        task = Task { @MainActor [weak self] in
            let job = Task.detached(priority: .userInitiated) { [weak self] in
                exportListingImages(modelURL: modelURL, modelName: modelName, angles: angles, colour: colour,
                                    background: background, folder: destination, isCancelled: { Task.isCancelled }) { done, angle in
                    Task { @MainActor [weak self] in
                        if self?.running == true { self?.progress = (done, angles.count, angle) }
                    }
                }
            }
            let result = await withTaskCancellationHandler { await job.value } onCancel: { job.cancel() }
            guard let self else { return }
            summary = result
            progress = nil
            running = false
            task = nil
            onFinish(result)
        }
    }

    /// Takes effect between views and inside a render; files already saved stay.
    func stop() { task?.cancel() }
}

/// Export Listing Images: choose views, colour and background, pick a folder, then render one view at a time.
/// Closing the sheet or Stop cancels before the next view (and inside a render); files already saved stay.
struct ListingImagesSheet: View {
    @EnvironmentObject var store: StudioStore
    @Environment(\.dismiss) private var dismiss
    let modelID: UUID

    @State private var selectedAngles = Set(ListingImageAngle.allCases.filter(\.selectedByDefault))
    @State private var materialID = ""
    @State private var background = ListingBackground.white
    @StateObject private var job = ListingExportJob()

    private var model: LocalModel? { store.localModels.first { $0.id == modelID } }
    private var chosenMaterial: Record? { materialID.isEmpty ? nil : store.filaments.first { $0.id == materialID } }
    private var chosenColour: SIMD3<Float>? { chosenMaterial.flatMap { listingColour(hex: $0.string("hexValue")) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Export listing images").font(.title2.weight(.bold))
                Text(model.map { "Square \(listingImagePixelSize) × \(listingImagePixelSize) px PNG renders of “\($0.name)” for marketplace listings. They show the model, not a print: check your marketplace’s photo rules, and add photos of a real print where you can." }
                     ?? "This model is no longer in your library.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(24)
            Divider()
            Form {
                Section("Views") {
                    ForEach(ListingImageAngle.allCases) { angle in
                        Toggle(angle.title, isOn: Binding(
                            get: { selectedAngles.contains(angle) },
                            set: { if $0 { selectedAngles.insert(angle) } else { selectedAngles.remove(angle) } }
                        ))
                    }
                }
                Section {
                    LabeledContent("Colour") {
                        HStack(spacing: 8) {
                            Circle()
                                .fill(swatch)
                                .frame(width: 14, height: 14)
                                .overlay(Circle().stroke(Color.studioHairline))
                                .accessibilityHidden(true)
                            Picker("Colour", selection: $materialID) {
                                Text("Neutral Grey").tag("")
                                if !materialID.isEmpty, chosenMaterial == nil {
                                    Text("Previously chosen material").tag(materialID)
                                }
                                ForEach(indexedRecords(store.filaments), id: \.id) { row in
                                    Text(materialDisplayName(displayName(for: row.record, fallback: "Untitled material"))).tag(row.record.id)
                                }
                            }
                            .labelsHidden()
                            .frame(maxWidth: 240)
                            .accessibilityLabel("Colour")
                        }
                    }
                    Picker("Background", selection: $background) {
                        ForEach(ListingBackground.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                } footer: {
                    Text(colourFooter).settingsFooterLayout()
                }
            }
            .formStyle(.grouped)
            .disabled(job.running)
            Divider()
            // Outside the Form, so the progress and result stay in view without scrolling.
            if job.progress != nil || job.summary != nil {
                statusView
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 12)
                Divider()
            }
            HStack {
                if job.running {
                    Button("Stop") { job.stop() }
                        .keyboardShortcut(.cancelAction)
                } else {
                    Button(job.summary == nil ? "Cancel" : "Done") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                }
                Spacer()
                if let summary = job.summary, !summary.saved.isEmpty, !job.running {
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting(summary.saved) }
                }
                Button("Export…") { chooseFolderAndExport() }
                    .buttonStyle(.borderedProminent)
                    .disabled(job.running || selectedAngles.isEmpty || model == nil)
            }
            .padding(20)
        }
        .frame(width: 520, height: 640)
        .onAppear {
            if materialID.isEmpty, store.listingSelectedMaterial != nil { materialID = store.filamentID }
        }
        .onDisappear { job.stop() }
    }

    private var swatch: Color {
        let colour = chosenColour ?? listingNeutralColour
        return Color(red: Double(colour.x), green: Double(colour.y), blue: Double(colour.z))
    }

    private var colourFooter: String {
        if chosenMaterial != nil, chosenColour == nil { return "Slant gave no colour for this material, so neutral grey is used." }
        if store.filaments.isEmpty { return "Materials load from your Slant account; until then the model is shown in neutral grey." }
        return "The colour is Slant’s swatch for the material, so it may differ a little from the printed filament."
    }

    @ViewBuilder
    private var statusView: some View {
        if let progress = job.progress, job.running {
            VStack(alignment: .leading, spacing: 6) {
                ProgressView(value: Double(progress.done), total: Double(max(progress.total, 1)))
                Text("Rendering the \(progress.current.title.lowercased()) view (\(progress.done + 1) of \(progress.total))…")
                    .font(.callout).foregroundStyle(.secondary)
            }
        } else if let summary = job.summary {
            VStack(alignment: .leading, spacing: 6) {
                Label(listingExportResultText(summary), systemImage: summary.saved.isEmpty ? "exclamationmark.triangle" : "checkmark.circle")
                ForEach(summary.failures, id: \.self) { Text($0).font(.callout).foregroundStyle(.orange) }
                if let folder = job.folder, !summary.saved.isEmpty {
                    Text(folder.path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
            }
        }
    }

    private func chooseFolderAndExport() {
        guard !job.running, let model, !selectedAngles.isEmpty else { return }
        let panel = NSOpenPanel()
        panel.title = "Export Listing Images"
        panel.message = "Choose a folder for the images. Existing files are kept; new names get a number."
        panel.prompt = "Export Here"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        let angles = ListingImageAngle.allCases.filter(selectedAngles.contains)
        let name = model.name
        let store = store
        job.start(modelURL: model.url, modelName: name, angles: angles, colour: chosenColour ?? listingNeutralColour,
                  background: background, folder: destination) { result in
            guard !result.saved.isEmpty else { return }
            // Counts only: a personalised model's name contains the buyer's text.
            store.activities.insert(Activity(title: "Export listing images", detail: "Saved \(result.saved.count) of \(angles.count)", success: true), at: 0)
        }
    }
}
