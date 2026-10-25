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

    private var current: Bool { preview != nil && previewSettings == settings }
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
                        if settings.kind != .internalWalls {
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
                            Text("The slicer’s walls round each slot use more filament: in a live Slant estimate, slots like these added about 27% to a 40 × 40 × 20 mm block’s price.")
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
                    Button(settings.kind.isExperimental ? "Save Experimental Test Copy" : settings.kind == .split ? "Save Two Part Copies" : "Apply to New Copy") { save() }
                        .buttonStyle(.borderedProminent)
                        .disabled(!current || !confirmed || (settings.kind.isExperimental && !experimentalConfirmed) || working || saving || store.busy || !shellsHeld)
                }
            }.padding(20).disabled(saving)
        }
        .frame(width: 780, height: 760)
        .onAppear { settings = .initial(for: source) }
        .onChange(of: settings.kind) { _, value in
            if value.keepsZUp { settings.orientation = .zUp }
        }
        .onChange(of: settings) { _, _ in
            cancelPreview(); preview = nil; previewSettings = nil; failure = nil
            confirmed = false; experimentalConfirmed = false
        }
        .onDisappear { cancelPreview() }
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
    private func updatePreview() {
        cancelPreview(); working = true; failure = nil; preview = nil; confirmed = false; experimentalConfirmed = false
        let request = settings, token = generation, mesh = source
        task = Task {
            let worker = Task.detached(priority: .userInitiated) {
                Result { try ReinforcementEngine.preview(mesh, settings: request, cancelled: { Task.isCancelled }) }
            }
            let result = await withTaskCancellationHandler(operation: { await worker.value }, onCancel: { worker.cancel() })
            guard !Task.isCancelled, generation == token else { return }
            working = false
            switch result {
            case .success(let value): preview = value; previewSettings = request
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
            let name = URL(fileURLWithPath: model.name).lastPathComponent
            let parts = [preview.mesh] + (preview.secondPart.map { [$0] } ?? [])
            let record = ReinforcementRecord(sourceID: model.id, settings: settings, addedVolumeMM3: preview.addedVolume, removedVolumeMM3: preview.removedVolume, created: Date(), inheritedCellRoofs: model.requiresZUp ? true : nil)
            var imported = true
            for (index, part) in parts.enumerated() {
                let suffix = parts.count > 1 ? "\(settings.kind.fileSuffix)-\(index + 1)" : settings.kind.fileSuffix
                let url = folder.appendingPathComponent("\(name)-\(suffix).stl")
                try part.binarySTL().write(to: url, options: .atomic)
                imported = store.importModel(url, improvement: model.designImprovement, intent: designEditIntent(model), reinforcement: record,
                                             sourceDetails: model.sourceDetails, origin: .studioToolCopy) && imported
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
