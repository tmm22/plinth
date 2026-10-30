import SwiftUI
import simd

// The model inspector's Size and base card and its sheets (MeshFit.swift does the geometry). Everything runs on this
// Mac; nothing is uploaded. Edits are STL-only and saved as separate library copies.

enum MeshFitTool: String, Sendable {
    case scale, flatBase, plinth, fitCoupon
    /// The button's title, in Title Case (the buttons add "…").
    var title: String {
        switch self {
        case .scale: return "Scale to Size"
        case .flatBase: return "Add Flat Base"
        case .plinth: return "Add Plinth"
        case .fitCoupon: return "Make Fit Coupon"
        }
    }
    /// The sheet's title: the button's, in sentence case.
    var sheetTitle: String {
        switch self {
        case .scale: return "Scale to size"
        case .flatBase: return "Add flat base"
        case .plinth: return "Add plinth"
        case .fitCoupon: return "Make fit coupon"
        }
    }
}

/// A store-driven sheet, counted in `isPresentingSheet`.
struct MeshFitRequest: Identifiable {
    let id = UUID()
    let tool: MeshFitTool
    let modelID: UUID
    let mesh: STLMesh
    /// The previewed file's own source details, carried to the copy.
    let fileDetails: ModelSourceDetails
}

/// Temporary folders for copies being saved; removed right after import, and at launch if a crash left one.
let meshFitTempFolderPrefix = "Plinth-MeshFit-"

/// Why `tool` can't edit this model, or nil when it can.
func meshFitEditBlockedReason(_ model: LocalModel, tool: MeshFitTool) -> String? {
    guard model.supportsPreview else {
        return model.supportsMeshPreview
            ? "Scaling and bases work on an STL copy. Use Save STL Copy below, then select the copy."
            : "Available for STL files."
    }
    switch tool {
    case .scale:
        // The same rule as the scale check: records on prepared or edited copies depend on their size.
        return canSaveScaledCopy(model) ? nil
            : "This copy records a placement or edits that depend on its size. Scale the original import instead."
    case .flatBase, .plinth:
        guard model.requiresZUp else { return nil }
        return model.fitCoupon == true
            ? "A fit coupon keeps the full part’s bed face. Add the base to the original, then make a new coupon."
            : "This copy has features that depend on its print layers. Add the base to the original, then reinforce that copy."
    case .fitCoupon:
        // The coupon keeps the bed face and the way up, so copies locked Z up (print-ready ones included) can have one.
        return nil
    }
}

/// Size label for a mesh's bounding box.
func meshFitSizeLabel(_ size: SIMD3<Float>) -> String { footprintLabel((size.x, size.y, size.z)) }

func meshFitAreaLabel(_ area: Double) -> String {
    "\(Int(area.rounded()).formatted()) mm²"
}

/// Height text for a prefilled field, without trailing zeros ("0.65", "1").
func meshFitHeightText(_ value: Float) -> String {
    String(format: "%g", (Double(value) * 100).rounded() / 100)
}

extension StudioStore {
    /// Opens a fit sheet for the selected model, unless another sheet or a request is up.
    func beginMeshFit(_ tool: MeshFitTool, model: LocalModel, loaded: LoadedPreviewMesh) {
        guard !isPresentingSheet, !busy, meshFitEditBlockedReason(model, tool: tool) == nil,
              loaded.url == model.url else { return }
        meshFitRequest = MeshFitRequest(tool: tool, modelID: model.id, mesh: loaded.mesh, fileDetails: loaded.sourceDetails)
    }

    /// Adds `data` (an already-checked binary STL) to the library as a separate copy named `name`.
    @discardableResult
    func saveMeshFitCopy(_ data: Data, name: String, of model: LocalModel, fileDetails: ModelSourceDetails,
                         activityTitle: String, locksZUp: Bool = false) -> Bool {
        do {
            let folder = FileManager.default.temporaryDirectory
                .appendingPathComponent("\(meshFitTempFolderPrefix)\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: folder) }
            let url = folder.appendingPathComponent(exportFileName(modelName: name, fileExtension: "stl"))
            try data.write(to: url, options: .atomic)
            let lineage = studioCopyLineage(model)
            // A fit coupon is locked Z up and marked as one, so the lock's wording names the coupon.
            guard importModelReturningID(url, intent: model.partIntent, sourceDetails: sourceDetailsForCopy(of: model, fromFile: fileDetails),
                                         inheritsZUpLock: lineage.inheritsZUpLock || locksZUp, origin: .studioToolCopy,
                                         keepsPlacement: lineage.keepsPlacement, fromPrintReadyCopy: lineage.fromPrintReadyCopy,
                                         fitCoupon: locksZUp) != nil else {
                return false
            }
            activities.insert(Activity(title: activityTitle, detail: model.name, success: true), at: 0)
            return true
        } catch {
            showError("The copy wasn’t saved: \(error.localizedDescription)")
            return false
        }
    }
}

// MARK: - Card

/// In memory, per model file version. Cleared when the app quits.
@MainActor enum WallThicknessCache {
    static var reports: [String: WallThicknessReport] = [:]
}

struct MeshFitCard: View {
    @EnvironmentObject var store: StudioStore
    let model: LocalModel
    let loaded: LoadedPreviewMesh
    @State private var expanded = false
    @State private var report: WallThicknessReport?
    @State private var checking = false
    @State private var progress = 0.0
    @State private var worker: Task<Void, Never>?
    @State private var breakdownExpanded = false

    private var cacheKey: String { "\(model.id.uuidString)|\(model.filePath)|\(loaded.mesh.triangleCount)" }

    var body: some View {
        Card {
            DisclosureGroup(isExpanded: $expanded) {
                VStack(alignment: .leading, spacing: 14) {
                    editTools
                    Divider()
                    couponSection
                    Divider()
                    thicknessSection
                }
                .padding(.top, 14)
                .frame(maxWidth: .infinity, alignment: .leading)
            } label: {
                SectionHeading(title: "Size and base",
                               caption: "Scale to a real size, flatten the bottom, add a plinth, cut a fit coupon or check wall thickness")
            }
            .studioDisclosureStyle()
        }
        .onAppear { report = WallThicknessCache.reports[cacheKey] }
        .onDisappear { worker?.cancel() }
    }

    @ViewBuilder
    private var editTools: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Now \(meshFitSizeLabel(loaded.mesh.maximum - loaded.mesh.minimum))")
                .font(.callout).foregroundStyle(.secondary)
            HStack(spacing: 8) {
                ForEach([MeshFitTool.scale, .flatBase, .plinth], id: \.self) { tool in
                    Button("\(tool.title)…") { store.beginMeshFit(tool, model: model, loaded: loaded) }
                        .disabled(store.busy || meshFitEditBlockedReason(model, tool: tool) != nil)
                        .help(meshFitEditBlockedReason(model, tool: tool) ?? "Saves a separate copy and keeps this model")
                }
            }
            // One note, for the first tool that is unavailable; the others share the reason or are available.
            if let reason = [MeshFitTool.scale, .flatBase, .plinth].lazy.compactMap({ meshFitEditBlockedReason(model, tool: $0) }).first {
                Text(reason).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Each saves a separate copy; this model is kept as it is.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var couponSection: some View {
        HStack(spacing: 12) {
            Button("\(MeshFitTool.fitCoupon.title)…") { store.beginMeshFit(.fitCoupon, model: model, loaded: loaded) }
                .disabled(store.busy || meshFitEditBlockedReason(model, tool: .fitCoupon) != nil)
                .help(meshFitEditBlockedReason(model, tool: .fitCoupon)
                      ?? "Saves a small test piece cut round a hole or pin, or a slice of the base, as a separate copy")
            Text("A small test piece, to check a fit before ordering the full part")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var thicknessSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            if checking {
                HStack(spacing: 10) {
                    ProgressView(value: progress).frame(maxWidth: 200)
                    Text("Checking wall thickness… \(Int(progress * 100))%")
                        .font(.callout).foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    Button("Stop") { worker?.cancel() }
                }
                .accessibilityElement(children: .combine)
            } else if let report {
                let summary = wallThicknessSummary(report, origin: loaded.mesh.minimum)
                Label(summary.line, systemImage: summary.isClear ? "checkmark.circle" : "info.circle")
                    .font(.callout)
                    .foregroundStyle(summary.isClear ? Color.green : Color.primary)
                DisclosureGroup("Breakdown", isExpanded: $breakdownExpanded) {
                    breakdown(report, summary: summary).padding(.top, 6)
                }
                .studioDisclosureStyle()
                .font(.callout)
                Button("Check Again", action: startCheck).disabled(store.busy)
            } else {
                HStack(spacing: 12) {
                    Button("Check Wall Thickness", action: startCheck)
                    Text("Advisory · measured on this Mac")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func breakdown(_ report: WallThicknessReport, summary: WallThicknessSummary) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if report.measuredFraction >= 0.5 {
                ForEach(Array(report.bands.enumerated()), id: \.offset) { _, band in
                    Text(wallThicknessBandLabel(band)).monospacedDigit()
                }
            }
            ForEach(summary.details, id: \.self) { line in
                Text(line).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Text("Measured inward from \(report.sampleCount.formatted()) points spread over the surface. Positions are from the model’s lowest corner. A guide only: it doesn’t block upload and isn’t a strength rating.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func startCheck() {
        guard !checking else { return }
        checking = true
        progress = 0
        let mesh = loaded.mesh, key = cacheKey
        worker = Task {
            let job = Task.detached(priority: .userInitiated) { () -> WallThicknessReport? in
                analyzeWallThickness(mesh, progress: { value in
                    Task { @MainActor in progress = max(progress, value) }
                }, isCancelled: { Task.isCancelled })
            }
            let result = await withTaskCancellationHandler { await job.value } onCancel: { job.cancel() }
            checking = false
            guard !Task.isCancelled, let result else { return }
            WallThicknessCache.reports[key] = result
            report = result
        }
    }
}

// MARK: - Sheet

/// What a shown fit coupon was made for.
struct FitCouponKey: Hashable, Sendable {
    let choice: FitCouponChoice
    let sliceHeightMM: Double?
}

struct FitCouponOutcome: Sendable {
    let key: FitCouponKey
    let result: Result<FitCouponResult, FitCouponError>
}

struct MeshFitSheet: View {
    @EnvironmentObject var store: StudioStore
    @Environment(\.dismiss) private var dismiss
    let request: MeshFitRequest

    // Scale to Size
    @State private var axis = MeshFitAxis.longest
    @State private var sizeText = ""
    // Add Flat Base
    @State private var suggestion: FlatBaseSuggestion?
    @State private var heightText = ""
    @State private var contactAtHeight: Double?
    // Add Plinth
    @State private var plinth = PlinthSettings()
    @State private var marginText = "3"
    @State private var thicknessText = "3"
    @State private var joinText = "0.5"
    // Make Fit Coupon
    @State private var couponFeatures: [FitCouponFeature]?
    @State private var couponChoice = FitCouponChoice.bottomSlice
    @State private var sliceText = meshFitHeightText(Float(fitCouponBottomSliceDefaultMM))
    /// The piece made for the current choice, so Save writes exactly what was shown.
    @State private var coupon: FitCouponOutcome?

    @State private var saving = false
    @State private var failure: String?
    @State private var worker: Task<Void, Never>?

    private var model: LocalModel? { store.localModels.first { $0.id == request.modelID } }
    private var extent: SIMD3<Float> { request.mesh.maximum - request.mesh.minimum }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text(request.tool.sheetTitle).font(.title2.weight(.bold))
                Text("\(model?.name ?? "This model") · now \(meshFitSizeLabel(extent))")
                    .font(.callout).foregroundStyle(.secondary)
                if request.tool == .fitCoupon {
                    // Above the form, so what Studio checks (and doesn't) is read before the piece is saved.
                    Text(fitCouponCaption)
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(24)
            Divider()
            Form {
                switch request.tool {
                case .scale: scaleForm
                case .flatBase: flatBaseForm
                case .plinth: plinthForm
                case .fitCoupon: couponForm
                }
                if let failure {
                    Label(failure, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .formStyle(.grouped)
            .disabled(saving)
            Divider()
            HStack {
                Button("Cancel") {
                    worker?.cancel()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Spacer()
                if saving { ProgressView().controlSize(.small) }
                // A free local save, like the other Size and base sheets.
                Button(saveTitle, action: save)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave || saving || model == nil)
            }
            .padding(20)
        }
        // The coupon sheet holds a preview, so it opens taller; every sheet stays within the main window's height.
        .frame(minWidth: 480, idealWidth: 520, minHeight: 420, idealHeight: request.tool == .fitCoupon ? 640 : nil)
        .onDisappear { worker?.cancel() }
        .task {
            guard request.tool == .fitCoupon else { return }
            let mesh = request.mesh
            let job = Task.detached(priority: .userInitiated) { fitCouponFeatures(in: mesh, isCancelled: { Task.isCancelled }) }
            // Closing the sheet stops the search.
            let found = await withTaskCancellationHandler { await job.value } onCancel: { job.cancel() }
            guard !Task.isCancelled, let found else { return }
            couponFeatures = found
            if !found.isEmpty, couponChoice == .bottomSlice { couponChoice = .feature(0) }
        }
        .task(id: couponKey) {
            guard request.tool == .fitCoupon, let key = couponKey, let region = couponRegion else { return }
            if coupon?.key == key { return }
            coupon = nil
            let mesh = request.mesh
            // Debounced so typing a height doesn't queue a cut per keystroke.
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            let job = Task.detached(priority: .userInitiated) { () -> Result<FitCouponResult, FitCouponError> in
                do { return .success(try fitCouponCopy(of: mesh, region: region, isCancelled: { Task.isCancelled })) }
                catch let error as FitCouponError { return .failure(error) }
                catch { return .failure(.cutFailed(error.localizedDescription)) }
            }
            let result = await withTaskCancellationHandler { await job.value } onCancel: { job.cancel() }
            guard !Task.isCancelled else { return }
            coupon = FitCouponOutcome(key: key, result: result)
        }
        .task {
            guard request.tool == .flatBase else { return }
            let mesh = request.mesh
            let found = await Task.detached(priority: .userInitiated) { mesh.flatBaseSuggestion() }.value
            guard !Task.isCancelled else { return }
            suggestion = found
            if heightText.isEmpty { heightText = meshFitHeightText(found.cutHeightMM ?? min(1, found.maximumCutMM)) }
        }
        .task(id: heightText) {
            guard request.tool == .flatBase else { return }
            contactAtHeight = nil
            guard let height = meshFitMillimetres(heightText), height < Double(extent.z) else { return }
            let mesh = request.mesh
            // Debounced so typing doesn't queue a pass per keystroke.
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            let area = await Task.detached(priority: .userInitiated) { mesh.crossSectionAreaMM2(atHeight: Float(height)) }.value
            guard !Task.isCancelled else { return }
            contactAtHeight = area
        }
    }

    private var saveTitle: String {
        switch request.tool {
        case .scale: return "Save Scaled Copy"
        case .flatBase: return "Save Copy with Flat Base"
        case .plinth: return "Save Copy with Plinth"
        case .fitCoupon: return "Save Fit Coupon"
        }
    }

    private var couponSliceHeight: Double? { meshFitMillimetres(sliceText) }

    private var couponRegion: FitCouponRegion? {
        guard let features = couponFeatures else { return nil }
        return fitCouponRegion(for: couponChoice, features: features, sliceHeightMM: couponSliceHeight,
                               meshMinimum: request.mesh.minimum, meshMaximum: request.mesh.maximum)
    }

    private var couponKey: FitCouponKey? {
        guard request.tool == .fitCoupon, couponFeatures != nil, couponRegion != nil else { return nil }
        return FitCouponKey(choice: couponChoice, sliceHeightMM: couponChoice == .bottomSlice ? couponSliceHeight : nil)
    }

    /// The piece made for the current choice, when it passed every check.
    private var couponReady: FitCouponResult? {
        guard let coupon, coupon.key == couponKey, case .success(let result) = coupon.result else { return nil }
        return result
    }

    private var scalePlan: ScaleToSizePlan? {
        meshFitMillimetres(sizeText).flatMap { try? scaleToSizePlan(extentMM: extent, axis: axis, targetMM: $0) }
    }

    private var plinthSettings: PlinthSettings? {
        guard let margin = meshFitMillimetres(marginText), let thickness = meshFitMillimetres(thicknessText),
              let join = meshFitMillimetres(joinText) else { return nil }
        var settings = plinth
        settings.marginMM = Float(margin); settings.thicknessMM = Float(thickness); settings.joinDepthMM = Float(join)
        return settings
    }

    private var canSave: Bool {
        switch request.tool {
        case .scale: return scalePlan?.fitsBuildVolume == true
        case .flatBase:
            guard let height = meshFitMillimetres(heightText) else { return false }
            return height < Double(extent.z)
        case .plinth: return plinthSettings.map { plinthSettingsProblem($0) == nil } ?? false
        case .fitCoupon: return couponReady != nil
        }
    }

    // MARK: Forms

    @ViewBuilder
    private var scaleForm: some View {
        Section {
            Picker("Measure", selection: $axis) {
                ForEach(MeshFitAxis.allCases) { Text($0.rawValue).tag($0) }
            }
            TextField("Size (mm)", text: $sizeText, prompt: Text("e.g. 50"))
        } footer: {
            Group {
                if let plan = scalePlan {
                    if plan.fitsBuildVolume {
                        Label("Result \(meshFitSizeLabel(plan.resultSizeMM)) · fits Slant’s 220 mm build volume", systemImage: "checkmark.circle")
                    } else {
                        Label("Result \(meshFitSizeLabel(plan.resultSizeMM)) · larger than Slant’s 220 mm build volume", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                } else if !sizeText.isEmpty {
                    Text("Enter a size in millimetres, such as 50 or 12.5.")
                } else {
                    Text("Scales evenly in all directions, so the shape keeps its proportions. Image-to-3D models don’t know their real size, so measure the object if you can.")
                }
            }
            .settingsFooterLayout()
        }
    }

    @ViewBuilder
    private var flatBaseForm: some View {
        Section {
            if let suggestion {
                LabeledContent("Flat on the bed now", value: meshFitAreaLabel(suggestion.currentContactMM2))
                TextField("Remove from the bottom (mm)", text: $heightText)
                LabeledContent("Flat base after the cut") {
                    Text(contactAtHeight.map(meshFitAreaLabel) ?? "…").monospacedDigit()
                }
            } else {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Measuring the bottom…").foregroundStyle(.secondary)
                }
            }
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                if let suggestion {
                    if suggestion.alreadyFlat {
                        Text("This model already sits on \(meshFitAreaLabel(suggestion.currentContactMM2)) of flat base, so it may not need one.")
                    } else if let cut = suggestion.cutHeightMM {
                        Text("Suggested: remove \(meshFitHeightText(cut)) mm for at least \(meshFitAreaLabel(suggestion.targetContactMM2)) flat on the bed.")
                    } else {
                        Text("Removing up to \(meshFitHeightText(suggestion.maximumCutMM)) mm doesn’t give \(meshFitAreaLabel(suggestion.targetContactMM2)) of flat base. A plinth may suit this model better.")
                    }
                }
                Text("Cuts the model level and fills the cut. Needs a closed mesh.")
                Text(elephantFootNote)
            }
            .settingsFooterLayout()
        }
    }

    @ViewBuilder
    private var plinthForm: some View {
        Section {
            Picker("Shape", selection: $plinth.shape) {
                ForEach(PlinthShape.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            TextField("Margin around the model (mm)", text: $marginText)
            TextField("Plinth thickness (mm)", text: $thicknessText)
            TextField("Sink the model into it (mm)", text: $joinText)
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                if let settings = plinthSettings, let problem = plinthSettingsProblem(settings) {
                    Text(problem).foregroundStyle(.orange)
                } else if plinthSettings == nil {
                    Text("Enter each size in millimetres.").foregroundStyle(.orange)
                }
                Text("Adds a base under the whole model, joined into one solid, so tall or top-heavy figures stand steady. Needs a closed mesh.")
                Text(plinthChamferNote)
            }
            .settingsFooterLayout()
        }
    }

    @ViewBuilder
    private var couponForm: some View {
        Section {
            if let features = couponFeatures {
                Picker("Cut round", selection: $couponChoice) {
                    ForEach(features.indices, id: \.self) { Text(features[$0].label).tag(FitCouponChoice.feature($0)) }
                    Text("Bottom slice").tag(FitCouponChoice.bottomSlice)
                }
                if couponChoice == .bottomSlice {
                    TextField("Slice height (mm)", text: $sliceText)
                }
                LabeledContent("Piece") {
                    Text(couponSizeText).monospacedDigit()
                }
                if let ready = couponReady {
                    STLSceneView(mesh: ready.mesh, showsPrintBed: true)
                        .frame(height: 180)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .accessibilityLabel("Preview of the fit coupon")
                }
            } else {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Finding holes and pins…").foregroundStyle(.secondary)
                }
            }
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                if let problem = couponProblem {
                    Text(problem).foregroundStyle(.orange)
                }
                if couponFeatures?.isEmpty == true {
                    Text("No round holes (through the base or running sideways) or pins standing on the part were found, so only the Bottom slice is offered.")
                }
                if let note = couponChoiceNote { Text(note) }
                if let ready = couponReady, let tall = fitCouponTallPieceNote(heightMM: ready.sizeMM.z) { Text(tall) }
                // `fitCouponCaption` is in the sheet's header, always in view.
                if let model, !model.derivesFromPrintReadyCopy, let copy = printReadyCopy(of: model, in: store.localModels) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(fitCouponPrintReadyHint)
                        Button("Show Copy") {
                            worker?.cancel()
                            dismiss()
                            store.select(copy)
                        }
                        .buttonStyle(.link)
                        .disabled(store.busy)
                    }
                }
            }
            .settingsFooterLayout()
        }
    }

    private var couponSizeText: String {
        if let ready = couponReady {
            return "\(meshFitSizeLabel(ready.sizeMM)) · \(Int(ready.volumeMM3.rounded()).formatted()) mm³"
        }
        if couponKey != nil, coupon?.key != couponKey { return "…" }
        return "—"
    }

    private var couponProblem: String? {
        if couponFeatures != nil, couponChoice == .bottomSlice, couponRegion == nil {
            return fitCouponSliceHeightProblem(modelHeightMM: Double(extent.z))
        }
        guard let coupon, coupon.key == couponKey, case .failure(let error) = coupon.result else { return nil }
        return error.localizedDescription
    }

    private var couponChoiceNote: String? {
        switch couponChoice {
        case .feature(let index):
            guard let features = couponFeatures, features.indices.contains(index) else { return nil }
            return fitCouponFeatureNote(features[index])
        case .bottomSlice:
            return "The whole footprint, from the bed up to the slice height, to check how the base and its holes fit a mating part."
        }
    }

    // MARK: Save

    private func save() {
        guard canSave, !saving, let model else { return }
        failure = nil
        saving = true
        let mesh = request.mesh, tool = request.tool
        let name: String, title: String
        let job: @Sendable () throws -> Data
        switch tool {
        case .scale:
            guard let plan = scalePlan else { saving = false; return }
            name = scaledToSizeCopyName(model.name, plan: plan)
            title = "Scale to size"
            job = { try mesh.scaledToSizeSTLData(axis: plan.axis, targetMM: plan.targetMM).data }
        case .flatBase:
            guard let height = meshFitMillimetres(heightText) else { saving = false; return }
            name = flatBaseCopyName(model.name)
            title = "Add flat base"
            job = { try mesh.flatBaseCopy(cutHeightMM: Float(height), isCancelled: { Task.isCancelled }).data }
        case .plinth:
            guard let settings = plinthSettings else { saving = false; return }
            name = plinthCopyName(model.name)
            title = "Add plinth"
            job = { try mesh.plinthCopy(settings, isCancelled: { Task.isCancelled }).data }
        case .fitCoupon:
            // Saves exactly the piece shown, already checked.
            guard let ready = couponReady else { saving = false; return }
            let data = ready.data
            name = fitCouponCopyName(model.name)
            title = "Make fit coupon"
            job = { data }
        }
        let details = request.fileDetails
        worker = Task {
            let running = Task.detached(priority: .userInitiated) { Result { try job() } }
            let result = await withTaskCancellationHandler { await running.value } onCancel: { running.cancel() }
            saving = false
            // Closing the sheet stops the work and nothing is saved.
            guard !Task.isCancelled else { return }
            switch result {
            case .success(let data):
                if store.saveMeshFitCopy(data, name: name, of: model, fileDetails: details, activityTitle: title,
                                         locksZUp: meshFitCopyLocksZUp(tool)) {
                    dismiss()
                }
            case .failure(let error):
                failure = error.localizedDescription
            }
        }
    }
}
