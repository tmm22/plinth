import SwiftUI
import UniformTypeIdentifiers
import AppKit

// MARK: - Library selection & next-step

enum LibrarySelection: Hashable {
    case local(UUID)
    case cloud(String)
}

enum ModelsNextStep: Equatable {
    case needsSetup, needsPlatform, needsModel, uploading, needsUpload, needsEstimate, estimateStale, readyForDraft
}

func librarySelection(selectedLocalID: UUID?, fileID: String) -> LibrarySelection? {
    if let selectedLocalID { return .local(selectedLocalID) }
    if !fileID.isEmpty { return .cloud(fileID) }
    return nil
}

func modelsNextStep(
    hasKey: Bool,
    platformID: String,
    hasSelection: Bool,
    hasLocalNeedingUpload: Bool,
    fileID: String,
    filamentID: String,
    hasEstimate: Bool,
    estimateIsCurrent: Bool,
    isUploading: Bool
) -> ModelsNextStep {
    if isUploading { return .uploading }
    if !hasKey { return .needsSetup }
    if platformID.isEmpty { return .needsPlatform }
    if !hasSelection { return .needsModel }
    if hasLocalNeedingUpload || fileID.isEmpty { return .needsUpload }
    if filamentID.isEmpty || !hasEstimate { return .needsEstimate }
    if !estimateIsCurrent { return .estimateStale }
    return .readyForDraft
}

// MARK: - ModelsView

struct ModelsView: View {
    @EnvironmentObject var store: StudioStore
    @State private var targeted = false
    @State private var search = ""
    @State private var selection: LibrarySelection?
    @State private var uploadFocusID: UUID?
    @State private var uploadConfirmedIDs: Set<UUID> = []
    @State private var uploadFailedIDs: Set<UUID> = []
    @State private var quantityText = "1"
    @State private var pendingRemoval: LibrarySelection?
    @State private var showHiddenFiles = false
    @State private var materialType: String?
    @State private var configurationRequest = 0
    @State private var pendingReuploadID: UUID?
    @State private var previewMesh: LoadedPreviewMesh?
    @State private var savingScaledCopy = false
    @State private var savingSTLCopy = false
    @Environment(\.undoManager) private var undoManager

    var body: some View {
        HSplitView {
            librarySidebar
                .frame(minWidth: 220, idealWidth: 250, maxWidth: 320)
            inspector
                .frame(minWidth: 580)
        }
        .searchable(text: $search, prompt: "Search models")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button("Import Model…") { store.importModel() }
                    Button("Import Model from URL…") { store.showImportFromURL = true }
                        .disabled(store.importFromURLBlockedReason != nil)
                } label: {
                    Label("Import Model", systemImage: "square.and.arrow.down")
                        .labelStyle(.titleAndIcon)
                } primaryAction: {
                    store.importModel()
                }
                .menuStyle(.button)
                .buttonStyle(.borderedProminent)
                .accessibilityLabel("Import Model")
            }
        }
        .confirmationDialog(
            pendingRemoval.map { modelRemovalTitle($0) } ?? "",
            isPresented: Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }),
            titleVisibility: .visible,
            presenting: pendingRemoval
        ) { target in
            switch target {
            case .local(let id):
                Button("Remove from Library", role: .destructive) { store.removeLocalModel(id: id, undoManager: undoManager) }
                    .disabled(isUploading(id))
            case .cloud(let id):
                Button("Delete from Slant", role: .destructive) {
                    Task { _ = await store.deleteCloudModel(id: id) }
                }
                .disabled(!store.hasKey || store.busy)
            }
            Button("Cancel", role: .cancel) {}
        } message: { target in
            Text(modelRemovalMessage(target))
        }
        .alert(
            "Slant didn’t delete this model",
            isPresented: Binding(get: { store.cloudDeleteRefusal != nil }, set: { if !$0 { store.cloudDeleteRefusal = nil } }),
            presenting: store.cloudDeleteRefusal
        ) { refusal in
            Button("Hide from List") { store.hideCloudModel(id: refusal.fileID) }
                .keyboardShortcut(.defaultAction)
            Button("Keep Showing", role: .cancel) {}
        } message: { refusal in
            Text(cloudDeleteRefusalMessage(refusal))
        }
        .sheet(item: renamingModel) { model in
            RenameModelSheet(model: model).environmentObject(store)
        }
        .onChange(of: materialType) { _, type in
            store.filamentID = filamentIDAfterTypeChange(currentID: store.filamentID, type: type, filaments: store.filaments)
        }
        .onChange(of: store.filamentID) { _, id in
            guard materialType != nil, let chosen = store.filaments.first(where: { $0.id == id }) else { return }
            if filamentType(chosen) != materialType { materialType = filamentType(chosen) }
        }
        .onAppear {
            Task { await store.refreshFilamentsIfStale() }
            syncSelectionFromStore()
            quantityText = "\(store.quantity)"
        }
        // The rename sheet belongs to this screen; never leave a rename pending once it is gone.
        .onDisappear { store.renamingModelID = nil }
        .onChange(of: store.selectedLocalID) { _, _ in syncSelectionFromStore() }
        .onChange(of: store.fileID) { _, _ in syncSelectionFromStore() }
        .onChange(of: selection) { _, new in applySelection(new) }
        .onChange(of: store.quantity) { _, new in quantityText = "\(new)" }
    }

    private var renamingModel: Binding<LocalModel?> {
        Binding(
            get: { store.renamingModelID.flatMap { id in store.localModels.first { $0.id == id } } },
            set: { if $0 == nil { store.renamingModelID = nil } }
        )
    }

    // MARK: Sidebar

    private var librarySidebar: some View {
        List(selection: $selection) {
            Section("On this Mac") {
                if store.localModels.isEmpty {
                    Text("No models on this Mac yet").font(.caption).foregroundStyle(.secondary)
                } else if filteredLocalModels.isEmpty {
                    Text("No local models match “\(search)”").font(.caption).foregroundStyle(.secondary)
                }
                ForEach(filteredLocalModels) { model in
                    HStack(spacing: 10) {
                        LocalModelThumbnail(model: model, size: 30)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(model.name).lineLimit(1)
                            StudioBadge(
                                text: model.remoteID == nil ? "Ready to upload" : "Uploaded",
                                tone: model.remoteID == nil ? .neutral : .success
                            )
                        }
                    }
                    .padding(.vertical, 3)
                    .tag(LibrarySelection.local(model.id))
                    .accessibilityLabel("\(model.name), \(model.remoteID == nil ? "Ready to upload" : "Uploaded")")
                    .contextMenu {
                        localFileActions(model.id)
                        Divider()
                        Button("Remove from Library…", role: .destructive) { pendingRemoval = .local(model.id) }
                            .disabled(isUploading(model.id))
                    }
                }
            }
            Section("Uploaded to Slant") {
                if !store.filesLoaded && store.files.isEmpty {
                    Text(store.hasKey ? "Not loaded yet" : "Connect your account to load cloud models")
                        .font(.caption).foregroundStyle(.secondary)
                } else if store.filesLoaded && store.files.isEmpty && search.isEmpty {
                    Text("No models uploaded yet").font(.caption).foregroundStyle(.secondary)
                } else if filteredCloudFiles.isEmpty && !search.isEmpty && !store.files.isEmpty {
                    Text("No cloud models match “\(search)”").font(.caption).foregroundStyle(.secondary)
                } else if filteredCloudFiles.isEmpty && !store.files.isEmpty {
                    Text("All uploaded models are hidden").font(.caption).foregroundStyle(.secondary)
                }
                ForEach(indexedRecords(filteredCloudFiles), id: \.id) { row in
                    let hidden = store.hiddenFileIDs.contains(row.record.id)
                    let linked = localModel(linkedTo: row.record.id, in: store.localModels)
                    HStack(spacing: 10) {
                        StudioTile(symbol: "icloud", imageURL: httpsPreviewImageURL(row.record), size: 30)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(cloudModelDisplayName(row.record)).lineLimit(1)
                            HStack(spacing: 4) {
                                StudioBadge(text: hidden ? "Hidden" : "In Slant", tone: hidden ? .neutral : .accent)
                                if linked != nil {
                                    StudioBadge(text: "On this Mac", tone: .success)
                                }
                            }
                        }
                    }
                    .opacity(hidden ? 0.6 : 1)
                    .padding(.vertical, 3)
                    .tag(LibrarySelection.cloud(row.record.id))
                    .accessibilityLabel(linked == nil ? cloudModelDisplayName(row.record) : "\(cloudModelDisplayName(row.record)), also on this Mac")
                    .contextMenu {
                        if let linked {
                            Button("Show Local Copy") { store.select(linked) }
                            Divider()
                        }
                        Button("Copy ID") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(row.record.id, forType: .string)
                        }
                        Divider()
                        if hidden {
                            Button("Show in List") { store.unhideCloudModel(id: row.record.id) }
                        } else {
                            Button("Hide from List") { store.hideCloudModel(id: row.record.id) }
                        }
                        Button("Delete from Slant…", role: .destructive) { pendingRemoval = .cloud(row.record.id) }
                            .disabled(!store.hasKey || store.busy)
                    }
                }
                if hiddenCloudCount > 0 {
                    Button(showHiddenFiles ? "Stop showing hidden models" : "Show \(hiddenCloudCount) hidden") {
                        showHiddenFiles.toggle()
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                }
                if store.hasKey {
                    if !store.filesLoaded || store.files.isEmpty {
                        Button("Load cloud models") {
                            Task { await store.refresh() }
                        }
                        .disabled(store.busy)
                    } else if store.filesHasMore {
                        Button("Load More") {
                            Task { await store.loadMoreFiles() }
                        }
                        .disabled(store.busy)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .onDeleteCommand {
            if let selection { pendingRemoval = selection }
        }
    }

    // MARK: Inspector

    private var inspector: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if let focusID = uploadFocusID, store.busy, store.selectedLocalID != focusID,
                       let uploading = store.localModels.first(where: { $0.id == focusID }) {
                        Label("Uploading \(uploading.name)…", systemImage: "arrow.up.circle")
                            .font(.callout).foregroundStyle(.secondary)
                    }

                    HStack(alignment: .center, spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(inspectorTitle).font(.title2.weight(.semibold)).lineLimit(2).textSelection(.enabled)
                            Text(inspectorSubtitle).font(.caption2.weight(.semibold)).tracking(1.3).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if case .local(let id) = selection {
                            Menu {
                                localFileActions(id)
                                if let model = store.localModels.first(where: { $0.id == id }) {
                                    // Opens the product editor only; nothing is uploaded or ordered from here.
                                    Button("Save as Product…") {
                                        store.openSavedProducts(prefill: savedProductPrefill(for: model, selectedFilamentID: store.filamentID))
                                    }
                                }
                                if store.selectedLocal?.remoteID != nil {
                                    Divider()
                                    Button("Upload again…") { pendingReuploadID = id }
                                        .disabled(store.busy || !store.hasKey || store.platformID.isEmpty)
                                }
                            } label: {
                                Label("More actions", systemImage: "ellipsis.circle")
                            }
                            .fixedSize()
                            .help(store.selectedLocal?.remoteID != nil ? "Rename, export, save as a product or upload again" : "Rename, export or save as a product")
                        }
                        if case .cloud(let id) = selection {
                            Menu {
                                if store.hiddenFileIDs.contains(id) {
                                    Button("Show in List") { store.unhideCloudModel(id: id) }
                                } else {
                                    Button("Hide from List") { store.hideCloudModel(id: id) }
                                }
                                Divider()
                                Button("Delete from Slant…", role: .destructive) { pendingRemoval = .cloud(id) }
                                    .disabled(removalDisabled(.cloud(id)))
                            } label: {
                                Label("Remove", systemImage: "trash")
                            }
                            .menuStyle(.button)
                            .buttonStyle(.bordered)
                            .fixedSize()
                            .help("Hide this model or delete it from Slant")
                        } else if let selection {
                            Button(role: .destructive) { pendingRemoval = selection } label: {
                                Label(removalButtonTitle(selection), systemImage: "trash")
                            }
                            .buttonStyle(.bordered)
                            .disabled(removalDisabled(selection))
                            .help(removalButtonTitle(selection))
                        }
                    }

                    previewBlock
                    if let local = store.selectedLocal, let loaded = previewMesh, loaded.url == local.url {
                        MeshHealthPanel(model: local, mesh: loaded.mesh, objectCount: loaded.objectCount)
                    }
                    scaleNoticeBlock
                    printConfigurationCard.id("print-configuration")
                    if let local = store.selectedLocal {
                        if local.supportsMeshPreview && !local.supportsPreview {
                            stlToolsNotice(local)
                        }
                        AutoImproveCard(model: local).id(local.id)
                        PrintOrientationCard(model: local).id(local.id)
                        DesignImprovementsCard(model: local).id(local.id)
                        ReinforcementCard(model: local).id(local.id)
                    }
                    if let file = selectedCloud {
                        modelAnalysisCard(file)
                    }
                }
                .padding(StudioMetrics.pagePadding)
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                nextStepBlock
                    .padding(.horizontal, StudioMetrics.pagePadding)
                    .padding(.vertical, 12)
                    .background(.regularMaterial)
                    .overlay(alignment: .top) { Divider() }
            }
            .onChange(of: configurationRequest) { _, _ in
                withAnimation { proxy.scrollTo("print-configuration", anchor: .top) }
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            urls.forEach { store.importModel($0) }
            return !urls.isEmpty
        } isTargeted: { targeted = $0 }
    }

    private var previewBlock: some View {
        ZStack(alignment: .bottom) {
            Group {
                if let local = store.selectedLocal {
                    ModelPreview(url: local.url, showsPrintBed: local.printRecipe != nil) { url, model in
                        previewMesh = model.map { LoadedPreviewMesh(url: url, model: $0) }
                    }
                    .frame(height: 260)
                } else {
                    Color(nsColor: .controlBackgroundColor).frame(height: 260)
                }
            }
            if store.selectedLocal == nil {
                VStack(spacing: 12) {
                    if let cloud = selectedCloud, let linked = localModel(linkedTo: cloud.id, in: store.localModels) {
                        Text("Cloud model selected").font(.headline)
                        Text("“\(linked.name)” in your library on this Mac is linked to this file.")
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                        Button("Show local copy") { store.select(linked) }
                            .buttonStyle(.borderedProminent)
                            .accessibilityLabel("Show local copy")
                        Button("Download a separate copy") { downloadSelected() }
                            .buttonStyle(.link)
                            .font(.caption)
                            .disabled(store.busy)
                            .help("Adds another copy of this model to your library")
                    } else if selectedCloud != nil {
                        Text("Cloud model selected").font(.headline)
                        Text("Download its model to inspect the shape in 3D.").foregroundStyle(.secondary)
                        Button("Download into library") { downloadSelected() }
                            .buttonStyle(.bordered)
                            .disabled(store.busy)
                            .accessibilityLabel("Download into library")
                    } else {
                        Text("Import a model to preview, upload, and estimate.")
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                        Text("or drop an STL, OBJ, or 3MF anywhere in this panel")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(22)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: StudioMetrics.cardRadius))
                .padding(20)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: StudioMetrics.cardRadius))
        .overlay(
            RoundedRectangle(cornerRadius: StudioMetrics.cardRadius)
                .stroke(targeted ? Color.studioAccent : Color.studioHairline, lineWidth: targeted ? 3 : 1)
        )
    }

    private var nextStepBlock: some View {
        let step = currentNextStep
        let uploadFailed = step == .needsUpload && (store.selectedLocal.map { uploadFailedIDs.contains($0.id) && $0.remoteID == nil } ?? false)
        return HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(selectedModelName).font(.headline).lineLimit(1)
                Text(actionStatus(step, uploadFailed: uploadFailed))
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if store.busy {
                ProgressView().controlSize(.small)
                    .accessibilityLabel(store.progress.isEmpty ? "Working" : store.progress)
            } else if uploadFailed {
                Button("Try upload again") { startUpload() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!store.hasKey || store.platformID.isEmpty)
            } else {
                nextStepAction(step)
            }
        }
        .confirmationDialog(
            "Upload another copy to Slant?",
            isPresented: Binding(get: { pendingReuploadID != nil }, set: { if !$0 { pendingReuploadID = nil } }),
            titleVisibility: .visible,
            presenting: pendingReuploadID
        ) { id in
            Button("Upload Another Copy") {
                guard store.selectedLocalID == id else { return }
                startUpload()
            }
            .disabled(store.busy || !store.hasKey || store.platformID.isEmpty)
            Button("Cancel", role: .cancel) {}
        } message: { id in
            Text(reuploadConfirmationMessage(name: store.localModels.first { $0.id == id }?.name ?? "This model"))
        }
    }

    @ViewBuilder
    private func localFileActions(_ id: UUID) -> some View {
        Button("Rename…") { store.renamingModelID = id }
        Button("Export…") { store.exportLocalModel(id: id) }
    }

    /// Shown once, above the STL-only tool cards, for OBJ and 3MF models.
    private func stlToolsNotice(_ local: LocalModel) -> some View {
        let loaded = previewMesh.flatMap { $0.url == local.url ? $0 : nil }
        let blocked = loaded.flatMap { stlCopyBlockedReason(format: $0.format, inexactFaces: $0.inexactFaces) }
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Label("These tools work on STL files.", systemImage: "info.circle")
                    .font(.callout)
                Spacer(minLength: 8)
                if let loaded, blocked == nil {
                    Button(savingSTLCopy ? "Saving…" : "Save STL copy") {
                        guard !savingSTLCopy else { return }
                        savingSTLCopy = true
                        Task {
                            await store.saveSTLCopy(of: local.id, mesh: loaded.mesh, inexactFaces: loaded.inexactFaces)
                            savingSTLCopy = false
                        }
                    }
                    .buttonStyle(.bordered)
                    .disabled(savingSTLCopy || store.busy)
                    .help("Adds a separate STL copy to your library. This \(loaded.format.displayName) file is kept as it is and is still what an upload sends.")
                }
            }
            if let blocked {
                Text(blocked).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 4)
    }

    @ViewBuilder
    private var scaleNoticeBlock: some View {
        if let local = store.selectedLocal, let loaded = previewMesh, loaded.url == local.url,
           let warning = scaleWarning(extentMM: loaded.mesh.maximum - loaded.mesh.minimum, fileExtension: local.url.pathExtension) {
            Card {
                VStack(alignment: .leading, spacing: 10) {
                    Label("Check this model’s scale", systemImage: "exclamationmark.triangle.fill")
                        .font(.headline)
                        .foregroundStyle(.orange)
                    Text(warning.message).font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if !canSaveScaledCopy(local) {
                        Text("Re-export it from your CAD tool in millimetres, or save a scaled copy from the original import.")
                            .font(.callout).foregroundStyle(.secondary)
                    } else if let reason = stlCopyBlockedReason(format: loaded.format, inexactFaces: loaded.inexactFaces) {
                        Text("Re-export it from your CAD tool in millimetres. \(reason)")
                            .font(.callout).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    } else if warning.suggestions.isEmpty {
                        Text("Re-export it from your CAD tool in millimetres, or scale it in a slicer, then import it again.")
                            .font(.callout).foregroundStyle(.secondary)
                    } else {
                        Text(scaledCopyExplanation(format: loaded.format))
                            .font(.callout).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        if warning.suggestions.count == 1, let suggestion = warning.suggestions.first {
                            Button(suggestion.title) { saveScaledCopy(local, mesh: loaded.mesh, factor: suggestion.factor) }
                                .buttonStyle(.bordered)
                                .disabled(savingScaledCopy || store.busy)
                        } else {
                            Menu("Save scaled copy") {
                                ForEach(warning.suggestions) { suggestion in
                                    Button(suggestion.title) { saveScaledCopy(local, mesh: loaded.mesh, factor: suggestion.factor) }
                                }
                            }
                            .fixedSize()
                            .disabled(savingScaledCopy || store.busy)
                        }
                    }
                }
            }
        }
    }

    private func actionStatus(_ step: ModelsNextStep, uploadFailed: Bool) -> String {
        if store.busy { return store.progress.isEmpty ? "Working…" : store.progress }
        if uploadFailed { return "Upload didn’t finish. Your local model is still available." }
        if step == .needsEstimate || step == .estimateStale || step == .readyForDraft {
            if printQuantity(quantityText) == nil { return "Enter a whole-number quantity from 1 to 10,000." }
            if chosenMaterialOutOfStock { return "This material is out of stock. Choose another material." }
            if store.filamentID.isEmpty { return "Choose a material to get your print estimate." }
            if step == .readyForDraft, let estimate = store.estimate {
                return "\(money(estimate["total"])) USD · Shipping calculated in draft"
            }
            if store.selectedLocal.map({ uploadConfirmedIDs.contains($0.id) }) == true {
                return "Upload complete. Your model is ready to estimate."
            }
        }
        return nextStepStatusText(step)
    }

    @ViewBuilder
    private func nextStepAction(_ step: ModelsNextStep) -> some View {
        switch step {
        case .needsSetup:
            Button("Connect Account") { store.requestSettings(.account) }
                .buttonStyle(.borderedProminent)
                .accessibilityLabel("Connect Account")
        case .needsPlatform:
            Button("Open Platforms") { store.destination = .catalog; store.catalogKind = .platforms }
                .buttonStyle(.borderedProminent)
                .accessibilityLabel("Open Platforms")
        case .needsModel:
            Button("Import Model…") { store.importModel() }
                .buttonStyle(.borderedProminent)
                .accessibilityLabel("Import Model")
        case .uploading:
            EmptyView()
        case .needsUpload:
            Button("Upload model") { startUpload() }
                .buttonStyle(.borderedProminent)
                .disabled(store.selectedLocal == nil || store.busy || !store.hasKey || store.platformID.isEmpty)
                .accessibilityLabel("Upload model")
        case .needsEstimate, .estimateStale:
            if store.filamentID.isEmpty || chosenMaterialOutOfStock {
                Button("Choose material") { configurationRequest += 1 }
                    .buttonStyle(.borderedProminent)
            } else if printQuantity(quantityText) == nil {
                Button("Edit quantity") { configurationRequest += 1 }
                    .buttonStyle(.borderedProminent)
            } else {
                Button(step == .estimateStale ? "Get a new estimate" : "Get estimate") { requestEstimate() }
                    .buttonStyle(.borderedProminent)
                    .disabled(store.fileID.isEmpty || !store.hasKey || store.busy)
            }
        case .readyForDraft:
            if printQuantity(quantityText) == nil {
                Button("Edit quantity") { configurationRequest += 1 }
                    .buttonStyle(.borderedProminent)
            } else if chosenMaterialOutOfStock {
                Button("Choose material") { configurationRequest += 1 }
                    .buttonStyle(.borderedProminent)
            } else {
                Button("New Order Draft…") { store.openOrderComposer() }
                    .buttonStyle(.borderedProminent)
                    .disabled(store.busy || store.filamentID.isEmpty)
                    .help("Add delivery details and review shipping before placing an order")
            }
        }
    }

    private var printConfigurationCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 18) {
                SectionHeading(title: "Print configuration", caption: selectedModelName)
                if filamentTypes(in: store.filaments).count > 1 {
                    LabeledContent("Type") {
                        Picker("Type", selection: $materialType) {
                            Text("All types").tag(String?.none)
                            ForEach(filamentTypes(in: store.filaments), id: \.self) { type in
                                Text(type).tag(String?.some(type))
                            }
                        }
                        .labelsHidden()
                        .frame(maxWidth: 280)
                        .accessibilityLabel("Material type")
                    }
                }
                LabeledContent("Material") {
                    Picker("Material", selection: $store.filamentID) {
                        Text("Choose a material").tag("")
                        if materialNeedsPreviousChoiceTag {
                            Text("Previously chosen material").tag(store.filamentID)
                        }
                        ForEach(indexedRecords(pickerFilaments), id: \.id) { row in
                            Text(filamentPickerLabel(row.record)).tag(row.record.id)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 280)
                    .accessibilityLabel("Material")
                }
                if store.filaments.isEmpty {
                    HStack {
                        Text("Load materials to choose a print material.")
                            .font(.caption).foregroundStyle(.secondary)
                        Button("Load materials") { Task { await store.loadCatalog(.materials) } }
                            .disabled(!store.hasKey || store.busy)
                    }
                }
                if let mismatch = preparedMaterialMismatch(recipeFilamentID: store.selectedLocal?.printRecipe?.materialID,
                                                           selectedFilamentID: store.filamentID, filaments: store.filaments) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(preparedMaterialMismatchMessage(mismatch))
                            .font(.callout).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        if mismatch.canApply, let name = mismatch.name {
                            Button("Use prepared material (\(name))") { store.filamentID = mismatch.filamentID }
                                .buttonStyle(.bordered)
                                .accessibilityLabel("Use prepared material, \(name)")
                        }
                    }
                }
                LabeledContent("Quantity") {
                    HStack(spacing: 10) {
                        TextField("Qty", text: $quantityText)
                            .frame(width: 64)
                            .onSubmit { commitQuantityText() }
                            .onChange(of: quantityText) { _, _ in commitQuantityText() }
                            .accessibilityLabel("Quantity")
                        Stepper("", value: $store.quantity, in: 1...10000)
                            .labelsHidden()
                            .accessibilityLabel("Quantity stepper")
                    }
                }
                if printQuantity(quantityText) == nil {
                    Label("Enter a whole number from 1 to 10,000.", systemImage: "exclamationmark.circle")
                        .font(.caption).foregroundStyle(.orange)
                } else if let notice = printQuantityNotice(quantityText) {
                    Label(notice, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.orange)
                }
                CompareEstimatesButton(modelName: selectedModelName) // EstimateComparison.swift
                if let estimate = store.estimate {
                    Divider()
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("\(money(estimate["total"])) USD")
                                .font(.system(size: 30, weight: .semibold, design: .rounded))
                            if store.estimateIsCurrent && printQuantity(quantityText) != nil {
                                Text("Print estimate · shipping calculated in draft")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            } else {
                                Label("Previous estimate · update your configuration and request a new estimate", systemImage: "exclamationmark.circle")
                                    .font(.caption).foregroundStyle(.orange)
                            }
                        }
                        Spacer()
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(displayedEstimateRows(estimate), id: \.0) { row in
                            HStack {
                                Text(row.0).foregroundStyle(.secondary)
                                Spacer()
                                Text(row.1)
                            }
                        }
                        .font(.callout)
                    }
                }
            }
        }
    }

    private func modelAnalysisCard(_ file: Record) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 14) {
                SectionHeading(title: "Model analysis", caption: cloudModelDisplayName(file))
                if let notes = slantProductionNotes(file) {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("Notes from Slant’s production team", systemImage: "text.bubble")
                            .font(.callout.weight(.semibold))
                        Text(notes).font(.callout).textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.studioAccent.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
                    .accessibilityElement(children: .combine)
                }
                if let imageURL = httpsPreviewImageURL(file) {
                    AsyncImage(url: imageURL) { phase in
                        switch phase {
                        case .success(let image):
                            image.resizable().scaledToFit().frame(maxHeight: 180).clipShape(RoundedRectangle(cornerRadius: 10))
                        case .failure:
                            EmptyView()
                        default:
                            ProgressView().frame(height: 80)
                        }
                    }
                }
                let entries = usableMetricEntries(file.metrics, supportRequired: supportRequiredFlag(file))
                if metricsAwaitingAnalysis(file.metrics) {
                    // `supportRequired` can be set at upload, before Slant has measured the part.
                    if let support = supportRequiredCaption(file) {
                        Text(support).font(.callout).foregroundStyle(.secondary)
                    }
                    Text("Analyzing… metrics appear once Slant finishes processing.")
                        .font(.callout).foregroundStyle(.secondary)
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 125))], alignment: .leading, spacing: 16) {
                        ForEach(entries, id: \.0) { entry in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(entry.1).font(.caption).foregroundStyle(.secondary)
                                Text(entry.2).font(.headline)
                            }
                        }
                    }
                }
                let dates = cloudFileDateRows(file)
                if !dates.isEmpty {
                    Text(dates.map { "\($0.0) \($0.1)" }.joined(separator: " · "))
                        .font(.caption).foregroundStyle(.secondary)
                }
                DisclosureGroup("Technical details") {
                    VStack(alignment: .leading, spacing: 12) {
                        Button("Copy ID") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(file.id, forType: .string)
                        }
                        .accessibilityLabel("Copy ID")
                        Text(file.id).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    }
                }
            }
        }
    }

    // MARK: Derived

    private var filteredLocalModels: [LocalModel] {
        let trimmed = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return store.localModels }
        return store.localModels.filter { $0.name.localizedCaseInsensitiveContains(trimmed) }
    }

    private var filteredCloudFiles: [Record] {
        cloudFilesMatching(
            visibleCloudFiles(store.files, hidden: store.hiddenFileIDs, showHidden: showHiddenFiles),
            search: search
        )
    }
    private var hiddenCloudCount: Int {
        store.files.filter { store.hiddenFileIDs.contains($0.id) }.count
    }

    private var selectedCloud: Record? { store.files.first { $0.id == store.fileID } }
    private var selectedModelName: String {
        store.selectedLocal?.name ?? selectedCloud.map(cloudModelDisplayName) ?? "Choose a model"
    }
    private var inspectorTitle: String {
        store.selectedLocal?.name ?? selectedCloud.map(cloudModelDisplayName) ?? "Your next creation"
    }
    private var inspectorSubtitle: String {
        if let local = store.selectedLocal {
            return ModelFileFormat(url: local.url).map { "\($0.displayName) MODEL · LOCAL PREVIEW" } ?? "MODEL · LOCAL"
        }
        return "MODEL INSPECTOR"
    }
    private var materialNeedsPreviousChoiceTag: Bool {
        !store.filamentID.isEmpty && !store.filaments.contains { $0.id == store.filamentID }
    }
    /// Includes the chosen material so the picker always has a matching tag while the selection catches up.
    private var pickerFilaments: [Record] {
        store.filaments.filter { filamentType($0) == materialType || materialType == nil || $0.id == store.filamentID }
    }
    private var chosenMaterialOutOfStock: Bool {
        guard let filament = store.filaments.first(where: { $0.id == store.filamentID }) else { return false }
        return filamentAvailability(filament) == false
    }
    private var currentNextStep: ModelsNextStep {
        let localNeedsUpload = store.selectedLocal.map { $0.remoteID == nil } ?? false
        let uploading = uploadFocusID != nil && store.busy && isUploadStageProgress(store.progress)
        let hasSelection = store.selectedLocal != nil || selectedCloud != nil
        return modelsNextStep(
            hasKey: store.hasKey,
            platformID: store.platformID,
            hasSelection: hasSelection,
            hasLocalNeedingUpload: localNeedsUpload,
            fileID: store.fileID,
            filamentID: store.filamentID,
            hasEstimate: store.estimate != nil,
            estimateIsCurrent: store.estimateIsCurrent,
            isUploading: uploading
        )
    }

    private func isUploading(_ id: UUID) -> Bool {
        uploadFocusID == id && store.busy
    }

    private func removalButtonTitle(_ target: LibrarySelection) -> String {
        if case .cloud = target { return "Delete from Slant…" }
        return "Remove from Library…"
    }

    private func removalDisabled(_ target: LibrarySelection) -> Bool {
        switch target {
        case .local(let id): return isUploading(id)
        case .cloud: return !store.hasKey || store.busy
        }
    }

    private func modelRemovalTitle(_ target: LibrarySelection) -> String {
        switch target {
        case .local: return "Remove this model from your library?"
        case .cloud: return "Delete this model from Slant?"
        }
    }

    private func modelRemovalMessage(_ target: LibrarySelection) -> String {
        switch target {
        case .local(let id):
            let model = store.localModels.first { $0.id == id }
            return localModelRemovalMessage(name: model?.name ?? "This model", isUploaded: model?.remoteID != nil,
                                            movesToTrash: model.map { isManagedModelCopy($0.url, supportDirectory: StudioStore.supportDirectory) } ?? true)
        case .cloud(let id):
            let name = store.files.first { $0.id == id }.map(cloudModelDisplayName) ?? "This model"
            return cloudModelDeletionMessage(name: name)
        }
    }

    private func commitQuantityText() {
        guard let value = printQuantity(quantityText) else { return }
        store.quantity = value
    }

    // MARK: Actions

    private func syncSelectionFromStore() {
        selection = librarySelection(selectedLocalID: store.selectedLocalID, fileID: store.fileID)
    }

    private func applySelection(_ new: LibrarySelection?) {
        switch new {
        case .local(let id):
            if let model = store.localModels.first(where: { $0.id == id }) {
                store.select(model)
            }
        case .cloud(let id):
            store.selectedLocalID = nil
            store.fileID = id
            store.estimate = nil
        case .none:
            break
        }
    }

    private func requestEstimate() {
        uploadConfirmedIDs.removeAll()
        Task { await store.quote() }
    }

    private func startUpload() {
        guard let model = store.selectedLocal else { return }
        let modelID = model.id
        uploadFocusID = modelID
        uploadConfirmedIDs.remove(modelID)
        uploadFailedIDs.remove(modelID)
        Task {
            let ran = await store.uploadModel(id: modelID)
            guard ran else {
                if uploadFocusID == modelID { uploadFocusID = nil }
                return
            }
            if store.localModels.first(where: { $0.id == modelID })?.remoteID != nil {
                uploadConfirmedIDs.insert(modelID)
                uploadFailedIDs.remove(modelID)
            } else {
                uploadFailedIDs.insert(modelID)
                uploadConfirmedIDs.remove(modelID)
            }
            if uploadFocusID == modelID { uploadFocusID = nil }
        }
    }

    private func saveScaledCopy(_ model: LocalModel, mesh: STLMesh, factor: Double) {
        guard canSaveScaledCopy(model), !savingScaledCopy else { return }
        savingScaledCopy = true
        let name = scaledCopyName(URL(fileURLWithPath: model.name).lastPathComponent, factor: factor)
        let intent = model.partIntent
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                Result { () -> URL in
                    let data = try mesh.scaledSTLData(by: factor)
                    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    let url = folder.appendingPathComponent("\(name).stl")
                    do { try data.write(to: url, options: .atomic) }
                    catch { try? FileManager.default.removeItem(at: folder); throw error }
                    return url
                }
            }.value
            switch result {
            case .success(let url):
                store.importModel(url, intent: intent)
                try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
            case .failure(let error):
                store.showError(error.localizedDescription)
            }
            savingScaledCopy = false
        }
    }

    private func downloadSelected() {
        let id = store.fileID
        let typeHint = selectedCloud?.string("type")
        Task {
            _ = await store.run("Download into library") {
                let response = try await store.client.request("GET", path: "/files/\(encodedSegment(id))")
                let file = responseObject(response)
                guard let source = file["fileURL"] as? String, let url = URL(string: source), url.scheme?.lowercased() == "https" else {
                    throw StudioError("No download URL was returned for this model.")
                }
                let temp = try await store.client.downloadModel(from: url)
                let ext = cloudDownloadExtension(recordType: (file["type"] as? String) ?? typeHint, downloadURL: url)
                let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".\(ext)")
                var moved = false
                defer { if !moved { try? FileManager.default.removeItem(at: temp) } }
                try FileManager.default.moveItem(at: temp, to: path)
                moved = true
                defer { try? FileManager.default.removeItem(at: path) }
                store.importModel(path)
                if let localID = store.selectedLocalID, let index = store.localModels.firstIndex(where: { $0.id == localID }) {
                    store.localModels[index].remoteID = id
                    store.localModels[index].name = (file["name"] as? String).flatMap {
                        $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0
                    } ?? "Untitled model"
                    store.fileID = id
                    store.saveModels()
                }
            }
        }
    }
}

func printQuantity(_ text: String) -> Int? {
    guard !text.isEmpty, text.allSatisfy({ $0.isASCII && $0.isNumber }),
          let value = Int(text), (1...10000).contains(value) else { return nil }
    return value
}

/// The large-quantity notice for the Models quantity field, where an extra zero is easy to type.
func printQuantityNotice(_ text: String) -> String? {
    printQuantity(text).flatMap { largeQuantityNotice($0) }
}

struct LoadedPreviewMesh {
    let url: URL
    let mesh: STLMesh
    var format: ModelFileFormat = .stl
    var objectCount = 1
    var inexactFaces = 0

    init(url: URL, mesh: STLMesh) { self.url = url; self.mesh = mesh }
    init(url: URL, model: PreviewModel) {
        self.url = url
        mesh = model.mesh
        format = model.format
        objectCount = model.objectCount
        inexactFaces = model.inexactFaces
    }
}

private func nextStepStatusText(_ step: ModelsNextStep) -> String {
    switch step {
    case .needsSetup: return "Connect your account to upload and estimate."
    case .needsPlatform: return "Choose or create a platform"
    case .needsModel: return "Import a model to get started."
    case .uploading: return "Uploading your model…"
    case .needsUpload: return "Upload this model to request an estimate."
    case .needsEstimate: return "Choose a material and get an estimate."
    case .estimateStale: return "Configuration changed · request a new estimate"
    case .readyForDraft: return "Estimate is ready · create an order draft when you’re set."
    }
}

func localModelRemovalMessage(name: String, isUploaded: Bool, movesToTrash: Bool = true) -> String {
    var message = movesToTrash
        ? "“\(name)” will be removed from Slant Studio and its library copy moved to the Trash. To restore it, choose Edit › Undo. The original file on your Mac isn’t touched."
        : "“\(name)” will be removed from Slant Studio. The original file on your Mac isn’t touched."
    if isUploaded { message += " The uploaded copy stays in your Slant account." }
    return message
}

func cloudModelDeletionMessage(name: String) -> String {
    "“\(name)” will be permanently deleted from your Slant 3D account. This can’t be undone. Copies in your library on this Mac are kept."
}

func cloudDownloadExtension(recordType: String?, downloadURL: URL) -> String {
    let fromType = (recordType ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if ["stl", "obj", "3mf"].contains(fromType) { return fromType }
    let ext = downloadURL.pathExtension.lowercased()
    if ["stl", "obj", "3mf"].contains(ext) { return ext }
    return "stl"
}

// MARK: - Import from URL

struct ImportFromURLSheet: View {
    @EnvironmentObject var store: StudioStore
    @Environment(\.dismiss) private var dismiss
    @State private var url = ""
    @State private var name = ""
    @State private var validation: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Import from URL").font(.title2.weight(.bold)).padding(24)
            Divider()
            Form {
                TextField("https://…", text: $url)
                TextField("Model name", text: $name)
                if let validation {
                    Label(validation, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                }
            }
            .formStyle(.grouped)
            .disabled(store.busy)
            Divider()
            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(store.busy)
                Spacer()
                Button("Import") { importModel() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(store.busy || !store.hasKey)
            }
            .padding(20)
        }
        .frame(width: 480, height: 320)
    }

    private func importModel() {
        if let problem = importFromURLValidation(url: url, name: name) {
            validation = problem
            return
        }
        validation = nil
        Task {
            if await store.importModelFromURL(url, name: name) {
                dismiss()
            }
        }
    }
}

// MARK: - Estimate / status helpers

func estimateRows(_ estimate: [String: Any]) -> [(String, String)] {
    var rows: [(String, String)] = []
    if estimate["pricePerUnit"] != nil { rows.append(("Price per unit", money(estimate["pricePerUnit"]))) }
    if let quantity = estimate["quantity"] { rows.append(("Quantity", String(describing: quantity))) }
    if estimate["subtotal"] != nil { rows.append(("Subtotal", money(estimate["subtotal"]))) }
    if let material = estimate["totalMaterial"] { rows.append(("Material", String(describing: material))) }
    if let time = estimate["estimatedPrintTime"] { rows.append(("Print time", "\(String(describing: time)) min")) }
    if estimate["bodyChargeCost"] != nil { rows.append(("Multi-part charge", money(estimate["bodyChargeCost"]))) }
    if estimate["oversizeSurcharge"] != nil { rows.append(("Oversize fee", money(estimate["oversizeSurcharge"]))) }
    if estimate["total"] != nil { rows.append(("Total", money(estimate["total"]))) }
    return rows
}

func displayedEstimateRows(_ estimate: [String: Any]) -> [(String, String)] {
    estimateRows(estimate).filter { $0.0 != "Total" && $0.0 != "Quantity" }
}

func estimateDisabledReason(hasKey: Bool, fileID: String, filamentID: String, busy: Bool, materialAvailable: Bool? = nil) -> String? {
    if busy { return nil }
    if !hasKey { return "Connect your account first" }
    if fileID.isEmpty { return "Upload this model first" }
    if filamentID.isEmpty { return "Choose a material" }
    if materialAvailable == false { return "This material is out of stock" }
    return nil
}

func orderDraftDisabledReason(estimateIsCurrent: Bool, filamentID: String, busy: Bool, materialAvailable: Bool? = nil) -> String? {
    if busy { return nil }
    if filamentID.isEmpty { return "Choose a material" }
    if materialAvailable == false { return "This material is out of stock" }
    if !estimateIsCurrent { return "Configuration changed · request a new estimate" }
    return nil
}

func uploadDisabledReason(hasKey: Bool, platformID: String) -> String? {
    if !hasKey || platformID.isEmpty { return "Connect your Slant account and choose a platform to upload." }
    return nil
}

func isUploadStageProgress(_ progress: String) -> Bool {
    if progress.hasPrefix("Upload") { return true }
    switch progress {
    case "Preparing upload…", "Requesting upload URL…", "Uploading model…", "Confirming upload and processing model…":
        return true
    default:
        return false
    }
}

func displayName(for record: Record, fallback: String) -> String {
    let named = record.string("name").trimmingCharacters(in: .whitespacesAndNewlines)
    return named.isEmpty ? fallback : named
}

func cloudModelDisplayName(_ record: Record) -> String {
    displayName(for: record, fallback: "Untitled model")
}

func catalogDisplayFallback(_ kind: Destination) -> String {
    switch kind {
    case .materials: return "Untitled material"
    case .components: return "Untitled component"
    case .stationery: return "Untitled stationery"
    case .platforms: return "Untitled platform"
    default: return "Untitled"
    }
}

func cloudFilesMatching(_ files: [Record], search: String) -> [Record] {
    let trimmed = search.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return files }
    return files.filter { cloudModelDisplayName($0).localizedCaseInsensitiveContains(trimmed) }
}

func cloudLibraryLoadsFirstPage(filesEmpty: Bool) -> Bool { filesEmpty }

func indexedRecords(_ records: [Record]) -> [(id: String, record: Record)] {
    records.enumerated().map { (id: "\($0.offset)-\($0.element.id)", record: $0.element) }
}

func money(_ value: Any?) -> String {
    let decimal: Decimal
    if let number = value as? NSDecimalNumber { decimal = number.decimalValue }
    else if let number = value as? NSNumber { decimal = number.decimalValue }
    else if let string = value as? String, let parsed = Decimal(string: string, locale: Locale(identifier: "en_US_POSIX")) { decimal = parsed }
    else { return "—" }
    let formatter = NumberFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.numberStyle = .decimal
    formatter.usesGroupingSeparator = false
    formatter.minimumFractionDigits = 2
    formatter.maximumFractionDigits = 2
    return formatter.string(from: NSDecimalNumber(decimal: decimal)).map { "$\($0)" } ?? "—"
}

func metricName(_ key: String) -> String {
    ["x": "Width", "y": "Depth", "z": "Height", "weight": "Weight", "volume": "Volume", "bodyCount": "Parts", "printTimeEstimate": "Print time",
     "supportRequired": "Needs supports", "supportVolumeEstimate": "Support volume (est.)"][key] ?? key
}

func metricUnit(_ key: String, _ metrics: [String: Any]) -> String {
    if key == "weight" {
        if let unit = metrics["weightUnit"] as? String, !unit.isEmpty { return unit }
    }
    return (metrics["units"] as? [String: String])?[key]
        ?? ["x": "mm", "y": "mm", "z": "mm", "weight": "g", "volume": "cm³", "printTimeEstimate": "min",
            "surfaceArea": "mm²", "supportVolumeEstimate": "cm³"][key]
        ?? ""
}

func metricDisplayValue(_ value: Any?) -> String? {
    guard let value, !(value is NSNull) else { return nil }
    let text = String(describing: value)
    if text.isEmpty || text == "<null>" || text.lowercased() == "null" { return nil }
    return text
}

/// Metric tiles for Model analysis. `supportRequired` (from `metrics` or the file record) shows as Yes/No in place of
/// surface area, which isn't useful for ordering.
func usableMetricEntries(_ metrics: [String: Any], supportRequired: Bool? = nil) -> [(String, String, String)] {
    ["x", "y", "z", "weight", "volume", "supportRequired", "supportVolumeEstimate", "bodyCount", "printTimeEstimate"].compactMap { key in
        if key == "supportRequired" {
            guard let supportRequired = supportRequired ?? supportRequiredFlag(metrics["supportRequired"]) else { return nil }
            return (key, metricName(key), supportRequired ? "Yes" : "No")
        }
        guard let display = metricDisplayValue(metrics[key]) else { return nil }
        let unit = metricUnit(key, metrics)
        let value = unit.isEmpty ? display : "\(display) \(unit)"
        return (key, metricName(key), value)
    }
}

/// The File schema's `notes`: "Production notes from Slant3D team". Nil when absent, null or blank.
func slantProductionNotes(_ record: Record) -> String? {
    guard let raw = record.values["notes"] as? String else { return nil }
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
}

/// Upload and last-update dates from the File schema's `createdAt` / `updatedAt`, when they parse.
/// The update is listed only when it differs from the upload.
func cloudFileDateRows(_ record: Record, formatter: (Date) -> String = { $0.formatted(date: .abbreviated, time: .shortened) }) -> [(String, String)] {
    func parse(_ key: String) -> Date? {
        guard let text = record.values[key] as? String else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }
    var rows: [(String, String)] = []
    let created = parse("createdAt")
    if let created { rows.append(("Uploaded", formatter(created))) }
    if let updated = parse("updatedAt"), created.map({ abs(updated.timeIntervalSince($0)) >= 1 }) ?? true {
        rows.append(("Updated", formatter(updated)))
    }
    return rows
}

/// True until Slant reports a measured metric; `supportRequired` alone can be decided at upload.
func metricsAwaitingAnalysis(_ metrics: [String: Any]) -> Bool {
    usableMetricEntries(metrics).allSatisfy { $0.0 == "supportRequired" }
}

func supportRequiredFlag(_ value: Any?) -> Bool? {
    guard let value, !(value is NSNull) else { return nil }
    if let bool = value as? Bool { return bool }
    if let number = value as? NSNumber { return number.boolValue }
    return nil
}

/// `supportRequired` from the file's `metrics`, or the record itself.
func supportRequiredFlag(_ record: Record) -> Bool? {
    supportRequiredFlag(record.metrics["supportRequired"]) ?? supportRequiredFlag(record.values["supportRequired"])
}

func supportRequiredCaption(_ record: Record) -> String? {
    supportRequiredFlag(record).map { $0 ? "Needs supports · Yes" : "Needs supports · No" }
}

func httpsPreviewImageURL(_ record: Record) -> URL? {
    let nested = (record.metrics["imageURL"] as? String) ?? (record.metrics["imageUrl"] as? String) ?? ""
    let raw = nested.isEmpty ? record.string("imageURL", "imageUrl") : nested
    guard let url = URL(string: raw), url.scheme?.lowercased() == "https" else { return nil }
    return url
}

func webhookTestResultMessage(_ result: WebhookTestResult) -> String {
    if let status = result.endpointStatus {
        if status == 200 {
            return "Slant attempted delivery; your endpoint returned HTTP 200"
        }
        return "Slant attempted delivery; your endpoint returned HTTP \(status)"
    }
    if let message = result.message?.trimmingCharacters(in: .whitespacesAndNewlines), !message.isEmpty {
        return message
    }
    return result.attempted ? "Slant attempted delivery." : "Test webhook failed."
}

func webhookResendResultMessage(_ result: WebhookResendResult) -> String {
    "Attempted \(result.attempted) · delivered \(result.delivered) · failed \(result.failed) · expired \(result.expired) · remaining \(result.remaining)"
}

func filamentPickerLabel(_ record: Record) -> String {
    let name = displayName(for: record, fallback: "Untitled material")
    if let stock = filamentAvailabilityLabel(record) { return "\(name) · \(stock)" }
    return name
}

func componentFactRows(_ record: Record) -> [(String, String)] {
    var rows: [(String, String)] = []
    if metricDisplayValue(record.values["price"]) != nil {
        let unit = record.string("priceUnit")
        rows.append(("Price", unit.isEmpty ? money(record.values["price"]) : "\(money(record.values["price"])) / \(unit)"))
    }
    let dimensions = record.string("dimensions")
    if !dimensions.isEmpty {
        let unit = record.string("dimensionUnit")
        rows.append(("Dimensions", unit.isEmpty ? dimensions : "\(dimensions) \(unit)"))
    }
    let weight = record.string("weight")
    if !weight.isEmpty { rows.append(("Weight", weight)) }
    if let tags = record.values["tags"] as? [Any] {
        let labels = tags.compactMap { metricDisplayValue($0) }
        if !labels.isEmpty { rows.append(("Tags", labels.joined(separator: ", "))) }
    } else if let tags = record.string("tags").nilIfEmpty {
        rows.append(("Tags", tags))
    }
    return rows
}

func componentCategoryLabel(_ record: Record, categories: [Record] = []) -> String? {
    let named = record.string("category", "categoryName").trimmingCharacters(in: .whitespacesAndNewlines)
    if !named.isEmpty { return named }
    let categoryID = record.string("categoryId", "categoryID")
    return componentCategoryName(id: categoryID, in: categories)
}

/// Ordered keyword → SF Symbol table; the first keyword found in a record's name, category, or tags wins.
private let catalogSymbolKeywords: [(keywords: [String], symbol: String)] = [
    (["magnet"], "circle.circle"),
    (["battery", "batteries", "cell"], "battery.100"),
    (["charger", "usb", "cable", "wire", "connector"], "cable.connector"),
    (["plug", "power supply", "adapter"], "powerplug"),
    (["led", "light", "bulb", "lamp"], "lightbulb"),
    (["screw", "bolt", "fastener", "threaded", "heat set", "standoff", "m2", "m3", "m4", "m5"], "wrench.and.screwdriver"),
    (["nut", "washer"], "hexagon"),
    (["feet", "foot", "bumper", "pad"], "circle.bottomhalf.filled"),
    (["key", "keyring", "keychain"], "key"),
    (["bearing", "wheel", "ring"], "circle.dotted"),
    (["motor", "fan"], "fan"),
    (["switch", "button"], "switch.2"),
    (["sensor", "pcb", "board", "chip"], "cpu"),
    (["speaker", "buzzer", "audio"], "speaker.wave.2"),
    (["spring", "gear", "hinge"], "gearshape"),
    (["clip", "clamp"], "paperclip"),
    (["chain", "lanyard", "strap", "cord"], "link"),
    (["glue", "adhesive", "tape"], "drop"),
    (["sticker", "label", "tag"], "tag"),
    (["card", "insert", "note", "flyer", "thank"], "text.rectangle"),
    (["box", "mailer", "carton"], "shippingbox"),
    (["bag", "pouch", "sleeve"], "bag"),
    (["envelope"], "envelope")
]

func catalogItemSymbol(_ record: Record, kind: Destination, categoryName: String? = nil) -> String {
    var haystack = [record.string("name"), categoryName ?? "", record.string("category", "categoryName")]
    if let tags = record.values["tags"] as? [Any] {
        haystack.append(contentsOf: tags.compactMap { metricDisplayValue($0) })
    }
    let words = Set(haystack.joined(separator: " ").lowercased()
        .components(separatedBy: CharacterSet.alphanumerics.inverted)
        .filter { !$0.isEmpty })
    let text = haystack.joined(separator: " ").lowercased()
    for entry in catalogSymbolKeywords {
        let hit = entry.keywords.contains { keyword in
            keyword.contains(" ") ? text.contains(keyword) : words.contains(keyword) || words.contains(keyword + "s") || words.contains(keyword + "es")
        }
        if hit { return entry.symbol }
    }
    return kind.icon
}

func catalogItemImageURL(_ record: Record) -> URL? {
    let raw = record.string("imageUrl", "imageURL", "image_url")
    guard let url = URL(string: raw), url.scheme?.lowercased() == "https" else { return nil }
    return url
}

func importFromURLValidation(url: String, name: String) -> String? {
    let trimmedURL = url.trimmingCharacters(in: .whitespacesAndNewlines)
    let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
    if !trimmedURL.lowercased().hasPrefix("https://") { return "Use an https:// link to import a model." }
    if trimmedName.isEmpty { return "Enter a name for the imported model." }
    return nil
}

private extension String {
    var nilIfEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

// MARK: - CatalogView

/// Materials, components and stationery. Platforms are managed in Settings › Account (PlatformsSettingsView.swift).
struct CatalogView: View {
    @EnvironmentObject var store: StudioStore
    let kind: Destination
    @State private var search = ""
    @State private var selected: Record?
    @State private var pendingOrderLine: OrderLine?
    @State private var materialType: String?

    private var records: [Record] {
        switch kind {
        case .materials: store.filaments
        case .components: store.components
        case .stationery: store.stationery
        default: []
        }
    }
    private var filtered: [Record] {
        let typed = kind == .materials ? filamentsMatching(records, type: materialType) : records
        return typed.filter { catalogRecordMatches($0, search: search) }
    }
    private var untitledFallback: String { catalogDisplayFallback(kind) }
    private var catalogLoaded: Bool { store.loadedCatalogs.contains(kind) }

    var body: some View {
        Group {
            if records.isEmpty {
                emptyCatalog
            } else {
                catalogContent
            }
        }
        .searchable(text: $search, prompt: "Search \(kind.rawValue.lowercased())")
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("Catalog", selection: $store.catalogKind) {
                    ForEach(Destination.catalogKinds) { kind in
                        Text(kind.rawValue).tag(kind)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 360)
            }
        }
        .sheet(item: $selected, onDismiss: presentPendingOrderDraft) { record in
            CatalogDetailSheet(record: record, kind: kind) { line in
                pendingOrderLine = line
            }
            .environmentObject(store)
        }
        .onAppear {
            if kind == .components {
                Task { await store.loadComponentCategories() }
            }
            if kind == .materials {
                Task { await store.refreshFilamentsIfStale() }
            }
        }
        .onChange(of: store.filaments.count) { _, _ in
            if let materialType, !filamentTypes(in: store.filaments).contains(materialType) {
                self.materialType = nil
            }
        }
        .onChange(of: kind) { _, new in
            selected = nil
            search = ""
            if new == .components {
                Task { await store.loadComponentCategories() }
            }
        }
    }

    @ViewBuilder
    private var emptyCatalog: some View {
        let loaded = catalogLoaded
        EmptyState(
            icon: kind.icon,
            title: loaded ? "Nothing on this account" : "Not loaded yet",
            detail: emptyCatalogDetail(loaded: loaded)
        ) {
            if !loaded {
                Button(store.hasKey ? "Load" : "Connect Slant Account…") {
                    if store.hasKey {
                        Task { await store.loadCatalog(kind) }
                    } else {
                        store.requestSettings(.account)
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(store.hasKey && store.busy)
            }
        }
    }

    private func emptyCatalogDetail(loaded: Bool) -> String {
        if loaded {
            return "No \(kind.rawValue.lowercased()) on this account yet."
        }
        if store.hasKey {
            return "Load live \(kind.rawValue.lowercased()) from Slant 3D."
        }
        return "Connect your account, then load live \(kind.rawValue.lowercased()) from Slant 3D."
    }

    private var catalogContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if kind == .materials, filamentTypes(in: records).count > 1 {
                    materialTypeChips
                        .padding(.horizontal, StudioMetrics.pagePadding)
                        .padding(.top, StudioMetrics.pagePadding)
                        .padding(.bottom, -8)
                }
                if filtered.isEmpty && !records.isEmpty {
                    Text("No \(kind.rawValue.lowercased()) match “\(search)”")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 24)
                        .padding(.top, 24)
                } else if !filtered.isEmpty {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: 16)], spacing: 16) {
                        ForEach(indexedRecords(filtered), id: \.id) { row in
                            Button { selected = row.record } label: {
                                catalogCard(row.record)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(displayName(for: row.record, fallback: untitledFallback))
                        }
                    }
                    .padding(StudioMetrics.pagePadding)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var materialTypeChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                typeChip("All", count: records.count, selected: materialType == nil) { materialType = nil }
                ForEach(filamentTypes(in: records), id: \.self) { type in
                    typeChip(type, count: filamentsMatching(records, type: type).count, selected: materialType == type) {
                        materialType = materialType == type ? nil : type
                    }
                }
            }
        }
    }

    private func typeChip(_ title: String, count: Int, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(title).font(.system(size: 12, weight: .semibold))
                Text("\(count)")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(selected ? Color.white.opacity(0.85) : .secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .foregroundStyle(selected ? Color.white : .primary)
            .background(selected ? Color.studioAccent : Color.studioCard, in: Capsule())
            .overlay(Capsule().stroke(selected ? Color.clear : Color.studioHairline))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title), \(count) materials")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func presentPendingOrderDraft() {
        guard let line = pendingOrderLine else { return }
        pendingOrderLine = nil
        store.openOrderComposer(line: line)
    }

    private func catalogCard(_ record: Record) -> some View {
        let category = kind == .components ? componentCategoryLabel(record, categories: store.componentCategories) : nil
        return VStack(alignment: .leading, spacing: 0) {
            catalogArtwork(record, category: category)
                .frame(height: 128)
                .frame(maxWidth: .infinity)
                .background(Color.primary.opacity(0.03))
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                Text(displayName(for: record, fallback: untitledFallback))
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(2)
                    .frame(height: 34, alignment: .topLeading)
                Text(catalogCardSubtitle(record, category: category))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    catalogCardBadge(record)
                    Spacer()
                }
            }
            .padding(14)
        }
        .background(Color.studioCard)
        .clipShape(RoundedRectangle(cornerRadius: StudioMetrics.cardRadius))
        .overlay(RoundedRectangle(cornerRadius: StudioMetrics.cardRadius).stroke(Color.studioHairline))
        .contentShape(RoundedRectangle(cornerRadius: StudioMetrics.cardRadius))
    }

    @ViewBuilder
    private func catalogArtwork(_ record: Record, category: String?) -> some View {
        if kind == .materials {
            Circle()
                .fill(Color(hex: record.string("hexValue")))
                .frame(width: 64, height: 64)
                .shadow(color: .black.opacity(0.14), radius: 8, y: 4)
                .overlay(Circle().stroke(Color.studioHairline))
        } else {
            StudioTile(
                symbol: catalogItemSymbol(record, kind: kind, categoryName: category),
                imageURL: catalogItemImageURL(record),
                size: 84
            )
        }
    }

    private func catalogCardSubtitle(_ record: Record, category: String?) -> String {
        switch kind {
        case .materials:
            return [record.string("profile"), record.string("color").capitalized]
                .filter { !$0.isEmpty }.joined(separator: " · ")
        case .components:
            return category ?? record.string("dimensions").nilIfEmpty.map { "\($0) mm" } ?? "Component"
        default:
            return record.string("description", "dimensions").nilIfEmpty ?? kind.rawValue
        }
    }

    @ViewBuilder
    private func catalogCardBadge(_ record: Record) -> some View {
        if kind == .materials {
            if let stock = filamentAvailabilityLabel(record) {
                StudioBadge(text: stock, tone: .warning)
            } else {
                StudioBadge(text: record.string("provider").nilIfEmpty ?? "Filament")
            }
        } else if metricDisplayValue(record.values["price"]) != nil {
            StudioBadge(text: money(record.values["price"]), tone: .accent)
        }
    }
}

struct CatalogDetailSheet: View {
    @EnvironmentObject var store: StudioStore
    @Environment(\.dismiss) private var dismiss
    let record: Record
    let kind: Destination
    /// Called before dismissing for New Order Draft with This Item; the composer opens once this sheet has closed.
    var onOrderDraft: (OrderLine) -> Void

    private var untitledFallback: String { catalogDisplayFallback(kind) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    Text(displayName(for: record, fallback: untitledFallback)).font(.title2.weight(.bold))
                    Spacer()
                    Button("Done") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                        .accessibilityLabel("Done")
                }
                catalogReadableFields(record, kind: kind, categories: store.componentCategories)
                DisclosureGroup("Technical details") {
                    VStack(alignment: .leading, spacing: 12) {
                        Button("Copy ID") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(record.id, forType: .string)
                        }
                        .accessibilityLabel("Copy ID")
                        JSONView(text: prettyJSON(hidingSecrets(record.values))).frame(height: 220)
                    }
                }
                HStack {
                    Spacer()
                    if kind == .materials {
                        Button("Use This Material") {
                            store.filamentID = record.id
                            dismiss()
                            store.destination = .models
                        }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                        .disabled(filamentAvailability(record) == false || store.busy)
                    }
                    if kind == .components || kind == .stationery {
                        Button("New Order Draft with This Item") {
                            onOrderDraft(OrderLine(
                                type: kind == .components ? "COMPONENT" : "STATIONERY",
                                reference: record.id
                            ))
                            dismiss()
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(store.busy)
                    }
                }
            }
            .padding(28)
        }
        .frame(width: 640, height: 520)
    }
}

@ViewBuilder
func catalogReadableFields(_ record: Record, kind: Destination, categories: [Record] = []) -> some View {
    if kind == .materials {
        HStack {
            Circle().fill(Color(hex: record.string("hexValue"))).frame(width: 28, height: 28)
            Text(record.string("color", "profile")).foregroundStyle(.secondary)
        }
        if let stock = filamentAvailabilityLabel(record) {
            Text(stock).foregroundStyle(.orange)
        }
    }
    if kind == .components {
        ForEach(componentFactRows(record), id: \.0) { row in
            LabeledContent(row.0, value: row.1)
        }
        if let category = componentCategoryLabel(record, categories: categories) {
            LabeledContent("Category", value: category)
        }
    }
    let description = record.string("description", "profile")
    if !description.isEmpty { Text(description).foregroundStyle(.secondary) }
    let provider = record.string("provider")
    if !provider.isEmpty { LabeledContent("Provider", value: provider) }
    let color = record.string("color")
    if kind != .materials, !color.isEmpty { LabeledContent("Color", value: color) }
}

func catalogRecordMatches(_ record: Record, search: String) -> Bool {
    let trimmed = search.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return true }
    let fields = [
        record.string("name"), record.string("description"), record.string("profile"),
        record.string("category"), record.string("categoryName"), record.string("provider"),
        record.string("color"), record.string("tags")
    ]
    return fields.contains { $0.localizedCaseInsensitiveContains(trimmed) }
}

func hidingSecrets(_ value: Any) -> Any {
    if var object = value as? [String: Any] {
        for key in Array(object.keys) where key.lowercased().contains("secret") { object[key] = "Hidden" }
        for (key, child) in object { object[key] = hidingSecrets(child) }
        return object
    }
    if let array = value as? [Any] { return array.map(hidingSecrets) }
    return value
}

extension Color {
    init(hex: String) {
        let number = UInt64(hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted), radix: 16) ?? 0x8D96A6
        self.init(
            red: Double((number >> 16) & 255) / 255,
            green: Double((number >> 8) & 255) / 255,
            blue: Double(number & 255) / 255
        )
    }
}
