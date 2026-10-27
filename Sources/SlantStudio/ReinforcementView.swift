import SwiftUI

struct ReinforcementCard: View {
    @EnvironmentObject var store: StudioStore
    let model: LocalModel
    @State private var expanded = false
    @State private var reviewing = false
    @State private var mesh: STLMesh?
    @State private var failure: String?

    var body: some View {
        Card {
            DisclosureGroup(isExpanded: $expanded) {
                VStack(alignment: .leading, spacing: 12) {
                    if let record = model.reinforcement {
                        Text("\(record.settings.kind.rawValue) applied to this copy.")
                        if let teardrops = record.teardropHoles {
                            Text(teardropHolesSummary(teardrops)).font(.callout).foregroundStyle(.secondary)
                        }
                        Text("Original preserved · Review the fit and test the print for its intended use.")
                            .font(.callout).foregroundStyle(.secondary)
                        if mesh != nil { Button("Add Another Reinforcement…") { reviewing = true }.disabled(store.busy) }
                        if let original = store.localModels.first(where: { $0.id == record.sourceID }) {
                            Button("Return to Original") { store.select(original) }
                        }
                    } else if !model.supportsPreview {
                        Text(stlOnlyToolNote(model) ?? stlCopyToolNote)
                    } else if let failure {
                        Text(failure).font(.callout).foregroundStyle(.secondary)
                    } else if mesh != nil {
                        Text("Add internal walls that open through the bed face, ribs, gussets, collars, fillets or overhang chamfers; match thin walls to line width; add teardrop holes or counterbore bridging; or split the part with alignment pins. The hole-wall ring gap is saved as an experimental test copy.")
                            .font(.callout).foregroundStyle(.secondary)
                        Button("Review Reinforcement…") { reviewing = true }.disabled(store.busy)
                    } else { ProgressView("Loading reinforcement tools…") }
                }.fixedSize(horizontal: false, vertical: true).padding(.top, 12)
            } label: {
                SectionHeading(title: "Reinforce this part", caption: model.reinforcement == nil ? "Add internal walls, ribs, gussets and other features you preview" : "Reinforcement copy · View details")
            }.studioDisclosureStyle()
        }
        .task(id: expanded) {
            guard expanded, model.supportsPreview, mesh == nil else { return }
            let url = model.url
            let result = await Task.detached(priority: .userInitiated) {
                Result { let value = try STLMesh.read(from: url); _ = try value.reinforcementSolid(); return value }
            }.value
            guard !Task.isCancelled else { return }
            switch result {
            case .success(let value): mesh = value
            case .failure(let error): failure = error.localizedDescription
            }
        }
        .sheet(isPresented: $reviewing) {
            if let mesh { ReinforcementReview(model: model, source: mesh) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .improveForPrintingOpenReinforce)) { note in
            // Review for Printing's "Open Reinforce" link (PrintReviewView.swift).
            if let id = note.object as? UUID, id == model.id { expanded = true }
        }
    }
}

private struct ReinforcementReview: View {
    @EnvironmentObject var store: StudioStore
    @Environment(\.dismiss) var dismiss
    let model: LocalModel
    let source: STLMesh
    @State private var settings = ReinforcementSettings()
    @State private var preview: ReinforcementPreview?
    @State private var previewSettings: ReinforcementSettings?
    @State private var failure: String?
    @State private var working = false
    @State private var saving = false
    @State private var confirmed = false
    @State private var experimentalConfirmed = false
    @State private var section = false
    @State private var task: Task<Void, Never>?
    @State private var generation = UUID()
    /// Teardrop hole roof: the holes Find Horizontal Holes listed, the ones ticked (none until the seller chooses), and
    /// the ticked set the current preview was made from.
    @State private var holes: [TeardropCandidate]?
    @State private var chosenHoles: Set<TeardropHoleKey> = []
    @State private var previewHoles: Set<TeardropHoleKey> = []

    /// The ticked holes that the preview reshapes instead of the placed region.
    private var activeHoles: [TeardropCandidate] {
        guard settings.kind == .teardrop, let holes else { return [] }
        return holes.filter { $0.eligible && chosenHoles.contains($0.key) }
    }
    private var current: Bool { preview != nil && previewSettings == settings && previewHoles == Set(activeHoles.map(\.key)) }
    /// A copy never has more separate shells than its source: a new one is a closed void Slant bills as a body.
    private var shellsHeld: Bool { preview.map { $0.shellsAfter <= $0.shellsBefore } ?? false }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                SectionHeading(title: "Reinforce this part", caption: "Position the change, protect clearances, then preview a new copy")
                Spacer()
            }.padding(20)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Picker("Treatment", selection: $settings.kind) {
                        ForEach(ReinforcementKind.offered) { Text($0.rawValue).tag($0) }
                    }
                    Text(settings.kind.explanation).font(.callout).foregroundStyle(.secondary)
                    if settings.kind == .teardrop { teardropHolesSection }
                    if settings.kind == .internalWalls {
                        Text(String(format: "Model envelope: %.2f × %.2f × %.2f mm · Slots cover the whole part; no placement is needed", source.maximum.x-source.minimum.x, source.maximum.y-source.minimum.y, source.maximum.z-source.minimum.z))
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        DisclosureGroup("Placement and dimensions · mm") {
                            VStack(alignment: .leading, spacing: 12) {
                                Text("Positions are measured from the model’s minimum X, Y and Z. Local dimensions rotate with the selected direction. Slightly overlap the surfaces to join.")
                                    .font(.callout).foregroundStyle(.secondary)
                                vectorFields("Position", value: $settings.offset)
                                vectorFields("Local size", value: $settings.size)
                                Picker("Direction", selection: $settings.orientation) {
                                    ForEach(PrintOrientation.allCases) { Text($0.label).tag($0) }
                                }.disabled(settings.kind.keepsZUp)
                                Picker("Turn about Z", selection: $settings.quarterTurns) {
                                    ForEach(0..<4, id: \.self) { Text("\($0 * 90)°").tag($0) }
                                }.pickerStyle(.segmented)
                                if settings.kind.keepsZUp { Text("This treatment depends on the print layers, so it faces Z up. Prepare the print orientation before adding it.").font(.caption).foregroundStyle(.secondary) }
                                if let label = settings.kind.thicknessLabel {
                                    HStack { Text(label); numberField($settings.thickness).frame(width: 90) }
                                }
                                if let label = settings.kind.boreLabel {
                                    HStack { Text(label); numberField($settings.boreDiameter).frame(width: 90) }
                                }
                                if settings.kind == .shell || settings.kind == .holeRing {
                                    HStack { Text("Gap width"); numberField($settings.gapWidth).frame(width: 90) }
                                }
                                if settings.kind == .bridge {
                                    HStack { Text("Layer height (Slant prints 0.2 mm)"); numberField($settings.layerHeight).frame(width: 90) }
                                }
                                if settings.kind == .thicken {
                                    HStack { Text("Estimated line width"); numberField($settings.lineWidth).frame(width: 90) }
                                }
                                Text(String(format: "Model envelope: %.2f × %.2f × %.2f mm", source.maximum.x-source.minimum.x, source.maximum.y-source.minimum.y, source.maximum.z-source.minimum.z))
                                    .font(.caption).foregroundStyle(.secondary)
                            }.padding(.top, 10)
                        }.studioDisclosureStyle()
                    }
                    DisclosureGroup("Keep-clear regions (\(settings.protectedRegions.count))") {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Protect space for mating parts, electronics, tools or movement. Neither added nor removed material may enter these regions.")
                                .font(.callout).foregroundStyle(.secondary)
                            ForEach($settings.protectedRegions) { $region in
                                VStack(alignment: .leading, spacing: 8) {
                                    vectorFields("Position", value: $region.offset)
                                    vectorFields("Size", value: $region.size)
                                    Button("Remove Region") { settings.protectedRegions.removeAll { $0.id == region.id } }
                                }.padding(10).background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
                            }
                            Button("Add Keep-Clear Region") {
                                settings.protectedRegions.append(ReinforcementBox(offset: (source.maximum-source.minimum)*0.25, size: (source.maximum-source.minimum)*0.5))
                            }.disabled(settings.protectedRegions.count >= 8)
                        }.padding(.top, 10)
                    }.studioDisclosureStyle()
                    HStack {
                        if settings.kind != .internalWalls && settings.kind != .teardrop {
                            Button("Suggest Position") { suggestPosition() }.disabled(working)
                        }
                        Button(working ? "Preparing Preview…" : "Update Preview") { updatePreview() }.disabled(working)
                        if working { ProgressView().controlSize(.small); Button("Stop") { cancelPreview() } }
                        Spacer()
                        Toggle("Cutaway view", isOn: $section).toggleStyle(.switch).disabled(!current || preview?.proposedSection == nil)
                    }
                    if let failure { Text(failure).font(.callout).foregroundStyle(.secondary) }
                    HStack(spacing: 14) {
                        previewPane("Original", mesh: section && current ? preview?.originalSection : source)
                        previewPane(current ? (settings.kind == .split ? "Proposed parts" : "Proposed copy") : "Choose Update Preview to see changes", mesh: current ? (section ? preview?.proposedSection : preview?.exploded ?? preview?.mesh) : nil)
                    }.frame(height: 235)
                    if section && current {
                        Text("Cutaway is for inspection only. The saved STL contains the complete part.").font(.caption).foregroundStyle(.secondary)
                    }
                    if current, let preview, preview.secondPart != nil {
                        Text(String(format: "Two parts · %.1f mm³ removed for pin holes · Each part is saved as its own copy", preview.removedVolume))
                            .font(.callout).foregroundStyle(.secondary)
                        Text("Prepare each part’s print orientation separately, then request a Slant quote for both.")
                            .font(.caption).foregroundStyle(.secondary)
                    } else if current, let preview {
                        if let detail = preview.detail {
                            Text(detail).font(.callout).foregroundStyle(.secondary)
                        }
                        Text(String(format: "Geometry: +%.1f mm³ added · %.1f mm³ removed · Overall envelope preserved", preview.addedVolume, preview.removedVolume))
                            .font(.callout).foregroundStyle(.secondary)
                        Text("Geometry volume is not a filament or strength estimate. Request a new Slant quote for this copy.")
                            .font(.caption).foregroundStyle(.secondary)
                        if settings.kind == .internalWalls {
                            Text("The slicer’s walls round each slot use more filament: in a live Slant estimate (25 Oct 2026), slots like these added about 27% to a 40 × 40 × 20 mm block’s price.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if current, let preview {
                        Text(reinforcementShellLine(before: preview.shellsBefore, after: preview.shellsAfter, split: preview.secondPart != nil))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }.padding(20).fixedSize(horizontal: false, vertical: true)
            }
            .disabled(saving)
            Divider()
            VStack(alignment: .leading, spacing: 12) {
                Toggle("I reviewed the placement; changed space is clear of mating parts and required movement", isOn: $confirmed)
                    .fixedSize(horizontal: false, vertical: true)
                if settings.kind.isExperimental {
                    Toggle("Save for test printing; this treatment is not a verified strength improvement", isOn: $experimentalConfirmed)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    Button("Cancel") { cancelPreview(); dismiss() }.keyboardShortcut(.cancelAction)
                    Spacer()
                    Button(settings.kind.isExperimental ? "Save Experimental Test Copy" : settings.kind == .split ? "Save Two-Part Copies" : "Apply to New Copy") { save() }
                        .buttonStyle(.borderedProminent)
                        .disabled(!current || !confirmed || (settings.kind.isExperimental && !experimentalConfirmed) || working || saving || store.busy || !shellsHeld)
                }
            }.padding(20).disabled(saving)
        }
        // Resizable within limits, opening shorter than the main window's minimum height; the settings scroll.
        .frame(minWidth: 700, idealWidth: 780, maxWidth: 960, minHeight: 520, idealHeight: 680, maxHeight: 900)
        .onAppear { settings = .initial(for: source) }
        .onChange(of: settings.kind) { _, value in
            if value.keepsZUp { settings.orientation = .zUp }
        }
        .onChange(of: settings) { _, _ in
            cancelPreview(); preview = nil; previewSettings = nil; failure = nil
            confirmed = false; experimentalConfirmed = false
        }
        .onChange(of: chosenHoles) { _, _ in
            cancelPreview(); preview = nil; previewSettings = nil; failure = nil
            confirmed = false; experimentalConfirmed = false
        }
        .onDisappear { cancelPreview() }
    }

    @ViewBuilder private var teardropHolesSection: some View {
        if let note = reinforceTeardropPrintReadyNote(model, library: store.localModels) {
            // A print-ready copy and its further copies have a chamfer and walls planned round the old holes; only the
            // copy's own follow-up, which re-prepares from the original, rebuilds them round the new shapes.
            Text(note).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            foundHolesSection
        }
    }

    @ViewBuilder private var foundHolesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button(holes == nil ? "Find Horizontal Holes" : "Find Again") { findHoles() }.disabled(working)
                if let holes {
                    let count = holes.filter(\.eligible).count
                    Text(count == 0 ? "None can take a teardrop roof" : "\(count) can take a teardrop roof · \(chosenHoles.count) ticked")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if let holes {
                let labels = teardropCandidateLabels(holes, low: source.minimum, high: source.maximum)
                if holes.isEmpty {
                    Text("No horizontal round holes found. You can still place a pointed roof by hand under Placement and dimensions.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    ForEach(holes.filter(\.eligible)) { hole in
                        Toggle((labels[hole.key] ?? teardropCandidateLabel(hole, low: source.minimum, high: source.maximum)), isOn: Binding(
                            get: { chosenHoles.contains(hole.key) },
                            set: { on in if on { chosenHoles.insert(hole.key) } else { chosenHoles.remove(hole.key) } }))
                            .fixedSize(horizontal: false, vertical: true)
                            .help(teardropCandidateDetail(hole, minimum: source.minimum))
                    }
                    if holes.contains(where: \.eligible) {
                        Text(teardropTickCaption + " While any hole is ticked, the preview reshapes those holes and Placement and dimensions isn’t used.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(holes.filter { !$0.eligible }) { hole in
                        Text((labels[hole.key] ?? teardropCandidateLabel(hole, low: source.minimum, high: source.maximum)) + ": " + (hole.skipped?.message ?? ""))
                            .font(.caption).foregroundStyle(.secondary)
                            .help(teardropCandidateDetail(hole, minimum: source.minimum))
                    }
                }
            }
        }
    }

    private func numberField(_ binding: Binding<Float>) -> some View {
        TextField("mm", value: binding, format: .number.precision(.fractionLength(0...3)))
            .textFieldStyle(.roundedBorder)
    }
    private func vectorFields(_ title: String, value: Binding<SIMD3<Float>>) -> some View {
        HStack {
            Text(title).frame(width: 75, alignment: .leading)
            ForEach(0..<3, id: \.self) { axis in
                Text(["X", "Y", "Z"][axis]).foregroundStyle(.secondary)
                numberField(Binding(get: { value.wrappedValue[axis] }, set: { value.wrappedValue[axis] = $0 }))
                    .accessibilityLabel("\(title) \(["X", "Y", "Z"][axis])")
            }
        }
    }
    private func previewPane(_ title: String, mesh: STLMesh?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.callout.weight(.medium))
            if let mesh {
                STLSceneView(mesh: mesh, showsPrintBed: false).id("\(generation)-\(title)-\(section)")
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            } else {
                Text("Choose the region, then choose Update Preview.").foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
    private func cancelPreview() {
        task?.cancel(); task = nil; generation = UUID(); working = false
    }
    private func suggestPosition() {
        cancelPreview(); working = true; failure = nil
        let request = settings, token = generation, mesh = source
        task = Task {
            let worker = Task.detached(priority: .userInitiated) {
                Result { try ReinforcementEngine.suggestPosition(mesh, settings: request, cancelled: { Task.isCancelled }) }
            }
            let result = await withTaskCancellationHandler(operation: { await worker.value }, onCancel: { worker.cancel() })
            guard !Task.isCancelled, generation == token else { return }
            working = false
            switch result {
            case .success(let value): settings = value
            case .failure(let error): failure = error.localizedDescription
            }
        }
    }
    private func findHoles() {
        cancelPreview(); working = true; failure = nil
        let token = generation, mesh = source
        task = Task {
            let worker = Task.detached(priority: .userInitiated) {
                Result { try teardropCandidates(in: mesh, isCancelled: { Task.isCancelled }) }
            }
            let result = await withTaskCancellationHandler(operation: { await worker.value }, onCancel: { worker.cancel() })
            guard !Task.isCancelled, generation == token else { return }
            working = false
            switch result {
            case .success(let value):
                holes = value
                chosenHoles = chosenHoles.filter { key in value.contains { $0.eligible && $0.key == key } }
            case .failure(let error): failure = error.localizedDescription
            }
        }
    }
    private func updatePreview() {
        cancelPreview(); working = true; failure = nil; preview = nil; confirmed = false; experimentalConfirmed = false
        let request = settings, token = generation, mesh = source, chosen = activeHoles
        task = Task {
            let worker = Task.detached(priority: .userInitiated) {
                Result {
                    chosen.isEmpty
                        ? try ReinforcementEngine.preview(mesh, settings: request, cancelled: { Task.isCancelled })
                        : try ReinforcementEngine.teardropHolesPreview(mesh, holes: chosen, protectedRegions: request.protectedRegions, cancelled: { Task.isCancelled })
                }
            }
            let result = await withTaskCancellationHandler(operation: { await worker.value }, onCancel: { worker.cancel() })
            guard !Task.isCancelled, generation == token else { return }
            working = false
            switch result {
            case .success(let value): preview = value; previewSettings = request; previewHoles = Set(chosen.map(\.key))
            case .failure(let error): failure = error.localizedDescription
            }
        }
    }
    private func save() {
        guard current, let preview, confirmed, !settings.kind.isExperimental || experimentalConfirmed, shellsHeld, !settings.kind.isWithdrawn else { return }
        saving = true
        do {
            let folder = studioTempFolderURL(prefix: reinforceTempFolderPrefix)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: folder) }
            let parts = [preview.mesh] + (preview.secondPart.map { [$0] } ?? [])
            let record = ReinforcementRecord(sourceID: model.id, settings: settings, addedVolumeMM3: preview.addedVolume, removedVolumeMM3: preview.removedVolume, created: Date(), inheritedCellRoofs: model.requiresZUp ? true : nil,
                                             teardropHoles: preview.teardrops)
            var imported = true
            for (index, part) in parts.enumerated() {
                let name = reinforcementCopyName(model.name, kind: settings.kind, part: parts.count > 1 ? index + 1 : nil)
                let url = folder.appendingPathComponent("\(name).stl")
                try part.binarySTL().write(to: url, options: .atomic)
                imported = store.importModel(url, improvement: model.designImprovement, intent: designEditIntent(model), reinforcement: record,
                                             sourceDetails: model.sourceDetails, inheritsZUpLock: model.requiresZUp,
                                             origin: .studioToolCopy, keepsPlacement: model.keepsPlacement == true, fromPrintReadyCopy: model.derivesFromPrintReadyCopy) && imported
            }
            if imported { dismiss() }
        } catch { store.showError(error.localizedDescription) }
        saving = false
    }
}

/// Reinforce's shell check line, such as "Separate shells: 1 before · 1 after".
func reinforcementShellLine(before: Int, after: Int, split: Bool) -> String {
    split ? "Separate shells: \(before) before · at most \(after) in each part after" : "Separate shells: \(before) before · \(after) after"
}

/// Reinforce's Teardrop hole roof on a print-ready copy or a copy made from one, in place of Find Horizontal Holes: where
/// to add teardrop holes instead, or why they aren't available. Nil for any other model.
func reinforceTeardropPrintReadyNote(_ model: LocalModel, library: [LocalModel]) -> String? {
    guard model.derivesFromPrintReadyCopy else { return nil }
    if printPreparationTeardropOfferApplies(model, library: library) { return reinforceTeardropOnPrintReadyCopyNote }
    let record = model.printPreparation
    if record?.hasTeardropHoles == true {
        return "Teardrop holes aren’t available on this copy: it already has them."
    }
    if record?.hiddenPockets?.filled != nil || model.filledPockets == true {
        return "Teardrop holes aren’t available on this copy: a new preparation from the original would bring its filled pockets back. Use Add Teardrop Holes… on the print-ready copy, then fill the new copy’s pockets."
    }
    guard let record else {
        return "Teardrop holes aren’t available on a copy made from a print-ready copy, whose chamfer and walls were planned round the old holes. Use Add Teardrop Holes… on the print-ready copy itself."
    }
    guard library.contains(where: { $0.id == record.sourceID }) else {
        return "Teardrop holes aren’t available on this copy: its original has been removed. Import the original again and make a print-ready copy of it."
    }
    return "Teardrop holes aren’t available on this copy. Make a print-ready copy of the original, then use Add Teardrop Holes… on it."
}

/// Reinforce's Teardrop hole roof on a print-ready copy, in place of Find Horizontal Holes.
let reinforceTeardropOnPrintReadyCopyNote = "On a print-ready copy, use Add Teardrop Holes… in its panel, which rebuilds the chamfer and walls round the new shapes."
