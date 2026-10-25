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

/// The next-step bar is hidden while nothing is selected and the only step is importing a model or connecting:
/// the empty inspector already says that and offers both buttons.
func showsModelsNextStepBar(hasSelection: Bool, step: ModelsNextStep) -> Bool {
    hasSelection || (step != .needsModel && step != .needsSetup)
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
                .modifier(ListingNoticeOverlay())  // "Listing details copied" (ListingAssets.swift)
        }
        .searchable(text: $search, prompt: "Search models")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button("Import Model…") { store.importModel() }
                    Button("Upload from URL…") { store.showImportFromURL = true }
                        .disabled(store.importFromURLBlockedReason != nil)
                    // Generates an STL from an OpenSCAD template into the library (Personalisation.swift); never uploads.
                    Button("Personalise from Template…") { store.chooseAndOpenPersonalisationTemplate() }
                    // Opens the sheet only (AccessoryDesignerView.swift); Claude is asked only after Start Design.
                    Button("Design an Accessory from a Photo…") { store.showAccessoryDesigner = true }
                    // Opens the replica sheet (ReplicaGeneratorView.swift); nothing is sent until Generate Replica.
                    Button("Generate a Replica from an Image…") { store.showReplicaGenerator = true }
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
        .modifier(SellerAddressNeededAlert()) // Order a Sample to Me… without a saved address (SellerAddressView.swift)
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
                    Text("No models on this Mac yet.").font(.caption).foregroundStyle(.secondary)
                } else if filteredLocalModels.isEmpty {
                    Text("No local models match “\(search)”.").font(.caption).foregroundStyle(.secondary)
                }
                // Same-named models get a format/date line (LibraryNameDetails.swift).
                let nameDetails = localModelDuplicateNameDetails(store.localModels)
                ForEach(filteredLocalModels) { model in
                    HStack(spacing: 10) {
                        LocalModelThumbnail(model: model, size: 30)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(model.name).lineLimit(1)
                            if let detail = nameDetails[model.id] {
                                Text(detail).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                            }
                            // "Preparing for printing…" while the automatic print-ready copy is made (PrintPreparation.swift).
                            PrintPreparationRowNote(queue: store.printPreparationQueue, modelID: model.id)
                            StudioBadge(
                                text: model.remoteID == nil ? "Ready to upload" : "Uploaded",
                                tone: model.remoteID == nil ? .neutral : .success
                            )
                        }
                    }
                    .padding(.vertical, 3)
                    .tag(LibrarySelection.local(model.id))
                    .accessibilityLabel("\(nameWithDetail(model.name, nameDetails[model.id])), \(model.remoteID == nil ? "Ready to upload" : "Uploaded")")
                    .contextMenu { localModelMenuItems(model) }
                    // Drag out to Finder or another app: a named copy of the file, never the library file (ModelDragExport.swift).
                    .onDrag { ModelDragExport.itemProvider(for: model) }
                }
            }
            Section("Uploaded to Slant") {
                if !store.filesLoaded && store.files.isEmpty {
                    Text(store.hasKey ? "Not loaded yet." : "Connect your account to load cloud models.")
                        .font(.caption).foregroundStyle(.secondary)
                } else if store.filesLoaded && store.files.isEmpty {
                    Text("No models uploaded yet.").font(.caption).foregroundStyle(.secondary)
                } else if filteredCloudFiles.isEmpty && !search.isEmpty && !store.files.isEmpty {
                    Text("No cloud models match “\(search)”.").font(.caption).foregroundStyle(.secondary)
                } else if filteredCloudFiles.isEmpty && !store.files.isEmpty {
                    Text("All uploaded models are hidden.").font(.caption).foregroundStyle(.secondary)
                }
                let cloudNameDetails = recordDuplicateNameDetailsByID(store.files, fallback: "Untitled model")
                ForEach(indexedRecords(filteredCloudFiles), id: \.id) { row in
                    let hidden = store.hiddenFileIDs.contains(row.record.id)
                    let linked = localModel(linkedTo: row.record.id, in: store.localModels)
                    HStack(spacing: 10) {
                        StudioTile(symbol: "icloud", imageURL: httpsPreviewImageURL(row.record), size: 30)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(cloudModelDisplayName(row.record)).lineLimit(1)
                            if let detail = cloudNameDetails[row.record.id] {
                                Text(detail).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                            }
                            // Every row here is in Slant, so only the exceptions are badged.
                            if hidden || linked != nil {
                                HStack(spacing: 4) {
                                    if hidden { StudioBadge(text: "Hidden", tone: .neutral) }
                                    if linked != nil { StudioBadge(text: "On this Mac", tone: .success) }
                                }
                            }
                        }
                    }
                    .opacity(hidden ? 0.6 : 1)
                    .padding(.vertical, 3)
                    .tag(LibrarySelection.cloud(row.record.id))
                    .accessibilityLabel(linked == nil
                                        ? nameWithDetail(cloudModelDisplayName(row.record), cloudNameDetails[row.record.id])
                                        : "\(nameWithDetail(cloudModelDisplayName(row.record), cloudNameDetails[row.record.id])), also on this Mac")
                    .contextMenu { cloudModelMenuItems(row.record.id) }
                }
                if hiddenCloudCount > 0 {
                    Button(showHiddenFiles ? "Stop Showing Hidden Models" : "Show \(hiddenCloudCount) Hidden") {
                        showHiddenFiles.toggle()
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                }
                if store.hasKey {
                    // After a load that found nothing, "No models uploaded yet." stands alone; Refresh reloads.
                    if !store.filesLoaded {
                        Button("Load Cloud Models") {
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

                    if hasSelection {
                        inspectorHeader
                        previewBlock
                        if let local = store.selectedLocal, let loaded = previewMesh, loaded.url == local.url {
                            MeshHealthPanel(model: local, mesh: loaded.mesh, objectCount: loaded.objectCount)
                            let details = modelSourceDetailsToShow(stored: local.sourceDetails, fromFile: loaded.sourceDetails)
                            if !details.isEmpty {
                                // 3MF designer and licence, or those an STL copy carried over; advisory only (ModelSourceDetails.swift).
                                ModelSourceDetailsPanel(details: details, edited: modelIsEditedCopy(local),
                                                        inherited: loaded.sourceDetails.isEmpty)
                            }
                        }
                        if let local = store.selectedLocal {
                            // The automatic print-ready copy: progress, or what it did (PrintPreparationView.swift).
                            PrintPreparationPanel(queue: store.printPreparationQueue, model: local).id(local.id)
                        }
                        scaleNoticeBlock
                        printConfigurationCard.id("print-configuration")
                        if let local = store.selectedLocal {
                            if local.supportsPreview {
                                ImproveForPrintingSection(model: local, loaded: previewMesh.flatMap { $0.url == local.url ? $0 : nil })
                                    .id(local.id)
                            } else if local.supportsMeshPreview {
                                // OBJ and 3MF: the tools need an STL copy, so only this notice is shown.
                                stlToolsNotice(local)
                            }
                        }
                        if let file = selectedCloud {
                            modelAnalysisCard(file)
                        }
                    } else {
                        emptyInspector
                    }
                }
                .padding(StudioMetrics.pagePadding)
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if showsModelsNextStepBar(hasSelection: hasSelection, step: currentNextStep) {
                    nextStepBlock
                        .padding(.horizontal, StudioMetrics.pagePadding)
                        .padding(.vertical, 12)
                        .background(.regularMaterial)
                        .overlay(alignment: .top) { Divider() }
                }
            }
            .onChange(of: configurationRequest) { _, _ in
                withAnimation { proxy.scrollTo("print-configuration", anchor: .top) }
            }
            .onReceive(NotificationCenter.default.publisher(for: .improveForPrintingOpenReinforce)) { note in
                // Review for Printing's "Open Reinforce" link: the card expands itself (ReinforcementView.swift).
                guard let id = note.object as? UUID, id == store.selectedLocalID else { return }
                withAnimation { proxy.scrollTo(improveForPrintingReinforceCardID, anchor: .top) }
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            // A model dragged out of this library is already in it, so it isn't imported again.
            let imports = modelDropURLsToImport(urls, supportDirectory: StudioStore.supportDirectory)
            imports.forEach { store.importModel($0, origin: .imported) }
            return !imports.isEmpty
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
                        Button("Show Local Copy") { store.select(linked) }
                            .buttonStyle(.borderedProminent)
                        Button("Download a Separate Copy") { downloadSelected() }
                            .buttonStyle(.link)
                            .font(.caption)
                            .disabled(store.busy)
                            .help("Adds another copy of this model to your library")
                    } else {
                        Text("Cloud model selected").font(.headline)
                        Text("Download its model to inspect the shape in 3D.").foregroundStyle(.secondary)
                        Button("Download into Library") { downloadSelected() }
                            .buttonStyle(.bordered)
                            .disabled(store.busy)
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

    private var inspectorHeader: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(inspectorTitle).font(.title2.weight(.semibold)).lineLimit(2).textSelection(.enabled)
                Text(inspectorSubtitle).font(.caption2.weight(.semibold)).tracking(1.3).foregroundStyle(.secondary)
            }
            Spacer()
            // One More menu for local and cloud models, with the same items as the library's context menu.
            Menu {
                if let local = store.selectedLocal {
                    localModelMenuItems(local)
                } else if let file = selectedCloud {
                    cloudModelMenuItems(file.id)
                }
            } label: {
                Label("More", systemImage: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .labelStyle(.iconOnly)
            .fixedSize()
            .help("More actions")
            .accessibilityLabel("More actions")
        }
    }

    /// Shown instead of the inspector while no model is selected. The next-action bar below still says what's missing.
    private var emptyInspector: some View {
        let libraryEmpty = store.localModels.isEmpty && store.files.isEmpty
        return VStack(spacing: 14) {
            Image(systemName: "cube.transparent")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(Color.studioAccent)
                .accessibilityHidden(true)
            Text(libraryEmpty ? "Import your first model" : "Choose a model")
                .font(.title2.weight(.semibold))
            Text(libraryEmpty
                 ? "Import an STL, OBJ or 3MF file to preview, upload and estimate it. You can also drop a file here."
                 : "Select a model in the library, or import a new one. You can also drop a file here.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Button("Import Model…") { store.importModel() }
                    .buttonStyle(.borderedProminent)
                if !store.hasKey {
                    // The connection is set up in the Settings window.
                    Button("Connect Slant Account…") { store.requestSettings(.account) }
                        .buttonStyle(.bordered)
                }
            }
        }
        .frame(maxWidth: 420)
        .padding(40)
        .frame(maxWidth: .infinity, minHeight: 360)
        // Fill the visible inspector height (less the page padding) so the drop box isn't a band at the top.
        .containerRelativeFrame(.vertical, alignment: .center) { length, _ in
            max(360, length - StudioMetrics.pagePadding * 2)
        }
        .overlay(
            RoundedRectangle(cornerRadius: StudioMetrics.cardRadius)
                .stroke(targeted ? Color.studioAccent : Color.studioHairline,
                        style: StrokeStyle(lineWidth: targeted ? 3 : 1, dash: targeted ? [] : [6, 4]))
        )
    }

    /// The More menu and a library row's context menu for a local model. Destructive items come last.
    @ViewBuilder
    private func localModelMenuItems(_ model: LocalModel) -> some View {
        Button("Rename…") { store.renamingModelID = model.id }
        Button("Export…") { store.exportLocalModel(id: model.id) }
        // Listing assets (ListingAssets.swift): local renders and clipboard text only; nothing is sent to Slant.
        if model.supportsMeshPreview {
            Button("Export Listing Images…") { store.beginExportingListingImages(for: model.id) }
            Button("Copy Listing Details") { store.copyListingDetails(for: model.id) }
        }
        // Opens the product editor only; nothing is uploaded or ordered from here.
        Button("Save as Product…") {
            store.openSavedProducts(prefill: savedProductPrefill(for: model, selectedFilamentID: store.filamentID))
        }
        if model.remoteID != nil {
            // Opens the composer for review only; nothing is created or paid from here (SellerAddress.swift).
            Button("Order a Sample to Me…") { store.orderSampleToMe(fileID: model.remoteID) }
                .disabled(store.busy || store.orderDraftBlockedReason != nil)
        }
        if model.remoteID != nil {
            Divider()
            // Only asks: the upload starts from the confirmation, and only for the selected model.
            Button("Upload Again…") {
                if store.selectedLocalID != model.id { store.select(model) }
                pendingReuploadID = model.id
            }
            .disabled(store.busy || !store.hasKey || store.platformID.isEmpty)
        }
        Divider()
        Button("Remove from Library…", role: .destructive) { pendingRemoval = .local(model.id) }
            .disabled(isUploading(model.id))
    }

    /// The More menu and a library row's context menu for an uploaded model. Destructive items come last.
    @ViewBuilder
    private func cloudModelMenuItems(_ id: String) -> some View {
        if let linked = localModel(linkedTo: id, in: store.localModels) {
            Button("Show Local Copy") { store.select(linked) }
            Divider()
        }
        Button("Copy ID") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(id, forType: .string)
        }
        // Opens the composer for review only; nothing is created or paid from here (SellerAddress.swift).
        Button("Order a Sample to Me…") { store.orderSampleToMe(fileID: id) }
            .disabled(store.busy || store.orderDraftBlockedReason != nil)
        Divider()
        if store.hiddenFileIDs.contains(id) {
            Button("Show in List") { store.unhideCloudModel(id: id) }
        } else {
            Button("Hide from List") { store.hideCloudModel(id: id) }
        }
        Button("Delete from Slant…", role: .destructive) { pendingRemoval = .cloud(id) }
            .disabled(removalDisabled(.cloud(id)))
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
            // While busy, the status line says what is running and the window toolbar shows the only spinner.
            if !store.busy {
                if uploadFailed {
                    Button("Try Upload Again") { startUpload() }
                        .buttonStyle(.borderedProminent)
                        .disabled(!store.hasKey || store.platformID.isEmpty)
                } else {
                    nextStepAction(step)
                }
            }
        }
        .confirmationDialog(
            "Upload this model again?",
            isPresented: Binding(get: { pendingReuploadID != nil }, set: { if !$0 { pendingReuploadID = nil } }),
            titleVisibility: .visible,
            presenting: pendingReuploadID
        ) { id in
            Button("Upload Again") {
                guard store.selectedLocalID == id else { return }
                startUpload()
            }
            .disabled(store.busy || !store.hasKey || store.platformID.isEmpty)
            Button("Cancel", role: .cancel) {}
        } message: { id in
            Text(reuploadConfirmationMessage(name: store.localModels.first { $0.id == id }?.name ?? "This model"))
        }
    }

    /// Shown for OBJ and 3MF models in place of the Improve for printing tools, which work on an STL copy.
    private func stlToolsNotice(_ local: LocalModel) -> some View {
        let loaded = previewMesh.flatMap { $0.url == local.url ? $0 : nil }
        let blocked = loaded.flatMap { stlCopyBlockedReason(format: $0.format, inexactFaces: $0.inexactFaces) }
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Label(stlToolsNoticeText, systemImage: "info.circle")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                if let loaded, blocked == nil {
                    Button(savingSTLCopy ? "Saving…" : "Save STL Copy") {
                        guard !savingSTLCopy else { return }
                        savingSTLCopy = true
                        Task {
                            await store.saveSTLCopy(of: local.id, mesh: loaded.mesh, inexactFaces: loaded.inexactFaces,
                                                    sourceDetails: loaded.sourceDetails)
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
                            Button(suggestion.title) { saveScaledCopy(local, mesh: loaded.mesh, factor: suggestion.factor, fileDetails: loaded.sourceDetails) }
                                .buttonStyle(.bordered)
                                .disabled(savingScaledCopy || store.busy)
                        } else {
                            Menu("Save Scaled Copy") {
                                ForEach(warning.suggestions) { suggestion in
                                    Button(suggestion.title) { saveScaledCopy(local, mesh: loaded.mesh, factor: suggestion.factor, fileDetails: loaded.sourceDetails) }
                                }
                            }
                            .fixedSize()
                            .disabled(savingScaledCopy || store.busy)
                        }
                    }
                    if let advisory = smallPartAdvisory(extentMM: loaded.mesh.maximum - loaded.mesh.minimum) {
                        Text(advisory).font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        } else if let local = store.selectedLocal, let loaded = previewMesh, loaded.url == local.url,
                  let advisory = smallPartAdvisory(extentMM: loaded.mesh.maximum - loaded.mesh.minimum) {
            // Advice only: upload, estimate and the draft stay available.
            Label(advisory, systemImage: "info.circle")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 4)
        }
    }

    private func actionStatus(_ step: ModelsNextStep, uploadFailed: Bool) -> String {
        if store.busy { return store.progress.isEmpty ? "Working…" : store.progress }
        if uploadFailed { return "Upload didn’t finish. Your local model is still available." }
        if step == .needsPlatform { return platformSetupStatus(currentPlatformSetupAction) }
        if step == .needsEstimate || step == .estimateStale || step == .readyForDraft {
            if printQuantity(quantityText) == nil { return "Enter a whole-number quantity from 1 to 10,000." }
            if chosenMaterialOutOfStock { return "This material is out of stock. Choose another material." }
            if store.filamentID.isEmpty { return "Choose a material to get your print estimate." }
            if step == .readyForDraft, let estimate = store.estimate {
                return "\(money(estimate["total"])) USD. Shipping is calculated in the draft."
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
            Button("Connect Slant Account…") { store.requestSettings(.account) }
                .buttonStyle(.borderedProminent)
        case .needsPlatform:
            switch currentPlatformSetupAction {
            case .createPlatform:
                // Opens the Create Platform sheet only; nothing is sent until it is submitted.
                Button("Create Platform…") { store.showPlatformComposer = true }
                    .buttonStyle(.borderedProminent)
                    .disabled(store.busy)
            case .chooseInSettings:
                Button("Choose Platform…") { store.requestSettings(.account) }
                    .buttonStyle(.borderedProminent)
            }
        case .needsModel:
            Button("Import Model…") { store.importModel() }
                .buttonStyle(.borderedProminent)
        case .uploading:
            EmptyView()
        case .needsUpload:
            Button("Upload Model") { startUpload() }
                .buttonStyle(.borderedProminent)
                .disabled(store.selectedLocal == nil || store.busy || !store.hasKey || store.platformID.isEmpty)
        case .needsEstimate, .estimateStale:
            if store.filamentID.isEmpty || chosenMaterialOutOfStock {
                Button("Choose Material") { configurationRequest += 1 }
                    .buttonStyle(.borderedProminent)
            } else if printQuantity(quantityText) == nil {
                Button("Edit Quantity") { configurationRequest += 1 }
                    .buttonStyle(.borderedProminent)
            } else {
                Button(step == .estimateStale ? "Get New Estimate" : "Get Estimate") { requestEstimate() }
                    .buttonStyle(.borderedProminent)
                    .disabled(store.fileID.isEmpty || !store.hasKey || store.busy)
            }
        case .readyForDraft:
            if printQuantity(quantityText) == nil {
                Button("Edit Quantity") { configurationRequest += 1 }
                    .buttonStyle(.borderedProminent)
            } else if chosenMaterialOutOfStock {
                Button("Choose Material") { configurationRequest += 1 }
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
                SectionHeading(title: "Print configuration")
                LabeledContent("Material") {
                    // One picker, grouped by type when there is more than one. Changing it marks the estimate stale.
                    Picker("Material", selection: $store.filamentID) {
                        Text("Choose a material").tag("")
                        if materialNeedsPreviousChoiceTag {
                            Text("Previously chosen material").tag(store.filamentID)
                        }
                        let sections = materialPickerSections(store.filaments)
                        if sections.count > 1 {
                            ForEach(sections, id: \.type) { section in
                                Section(section.type) {
                                    ForEach(indexedRecords(section.materials), id: \.id) { row in
                                        Text(filamentPickerLabel(row.record)).tag(row.record.id)
                                    }
                                }
                            }
                        } else {
                            ForEach(indexedRecords(store.filaments), id: \.id) { row in
                                Text(filamentPickerLabel(row.record)).tag(row.record.id)
                            }
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
                        Button("Load Materials") { Task { await store.loadCatalog(.materials) } }
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
                            Button("Use Prepared Material (\(name))") { store.filamentID = mismatch.filamentID }
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
                                Text("Print estimate. Shipping is calculated in the draft.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            } else {
                                Label("Previous estimate. The configuration has changed, so get a new estimate.", systemImage: "exclamationmark.circle")
                                    .font(.caption).foregroundStyle(.orange)
                            }
                        }
                        Spacer()
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(displayedEstimateRows(estimate, bodyCount: estimateBodyCount(estimateContext: store.estimateContext, file: selectedCloud)), id: \.0) { row in
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
                SectionHeading(title: "Model analysis")
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
                    Text("Analysing… Metrics appear once Slant finishes processing.")
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
                }.studioDisclosureStyle()
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
        return "MODEL · UPLOADED TO SLANT"
    }
    private var hasSelection: Bool { store.selectedLocal != nil || selectedCloud != nil }
    private var currentPlatformSetupAction: PlatformSetupAction {
        platformSetupAction(platformsLoaded: store.loadedCatalogs.contains(.platforms), platformCount: store.platforms.count)
    }
    private var materialNeedsPreviousChoiceTag: Bool {
        !store.filamentID.isEmpty && !store.filaments.contains { $0.id == store.filamentID }
    }
    private var chosenMaterialOutOfStock: Bool {
        guard let filament = store.filaments.first(where: { $0.id == store.filamentID }) else { return false }
        return filamentAvailability(filament) == false
    }
    private var currentNextStep: ModelsNextStep {
        let localNeedsUpload = store.selectedLocal.map { $0.remoteID == nil } ?? false
        let uploading = uploadFocusID != nil && store.busy && isUploadStageProgress(store.progress)
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

    private func saveScaledCopy(_ model: LocalModel, mesh: STLMesh, factor: Double, fileDetails: ModelSourceDetails) {
        guard canSaveScaledCopy(model), !savingScaledCopy else { return }
        savingScaledCopy = true
        let name = scaledCopyName(URL(fileURLWithPath: model.name).lastPathComponent, factor: factor)
        let intent = model.partIntent
        let details = sourceDetailsForCopy(of: model, fromFile: fileDetails)
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                Result { () -> URL in
                    let data = try mesh.scaledSTLData(by: factor)
                    let folder = studioTempFolderURL(prefix: scaledCopyTempFolderPrefix)
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    let url = folder.appendingPathComponent("\(name).stl")
                    do { try data.write(to: url, options: .atomic) }
                    catch { try? FileManager.default.removeItem(at: folder); throw error }
                    return url
                }
            }.value
            switch result {
            case .success(let url):
                store.importModel(url, intent: intent, sourceDetails: details, origin: .studioToolCopy)
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
                store.importModel(path, origin: .downloadedFromSlant)
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
    var sourceDetails = ModelSourceDetails()

    init(url: URL, mesh: STLMesh) { self.url = url; self.mesh = mesh }
    init(url: URL, model: PreviewModel) {
        self.url = url
        mesh = model.mesh
        format = model.format
        objectCount = model.objectCount
        inexactFaces = model.inexactFaces
        sourceDetails = model.sourceDetails
    }
}

/// The Reinforce card's scroll position in the inspector, for Review for Printing's "Open Reinforce" link.
let improveForPrintingReinforceCardID = "improve-for-printing-reinforce"

/// Shown for OBJ and 3MF models in place of the Improve for printing tools.
let stlToolsNoticeText = "The Improve for printing tools work on STL files, so they use a separate STL copy of this model."

/// The optional geometry tools for an STL model, collapsed and in the order they're usually used: Review for Printing
/// first, then Repair and simplify, Size and base (once the preview's mesh is loaded), Optimise for purpose,
/// Auto-improve, Reinforce and Design improvements. Each saves a separate copy; this view only arranges them. Design
/// improvements appears only when it can edit this model (a plain rectangular box) or when the model is a copy with an
/// edge edit, whose summary it shows.
struct ImproveForPrintingSection: View {
    let model: LocalModel
    /// The inspector's preview of this model, which Size and base works from.
    let loaded: LoadedPreviewMesh?
    /// The model's mesh, loaded only when its edges can be edited automatically.
    @State private var edgeEditableMesh: STLMesh?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeading(title: "Improve for printing", caption: "Optional · Each tool saves a separate copy and keeps your original.")
                .padding(.top, 4)
            PrintReviewCard(model: model)
            MeshToolsCard(model: model)
            if let loaded {
                MeshFitCard(model: model, loaded: loaded)
            }
            PrintOrientationCard(model: model)
            AutoImproveCard(model: model)
            ReinforcementCard(model: model).id(improveForPrintingReinforceCardID)
            if model.designImprovement != nil || edgeEditableMesh != nil {
                DesignImprovementsCard(model: model, mesh: edgeEditableMesh)
            }
        }
        .task(id: model.id) {
            edgeEditableMesh = nil
            guard model.supportsPreview, model.designImprovement == nil else { return }
            let url = model.url
            let mesh = await Task.detached(priority: .userInitiated) { () -> STLMesh? in
                guard let mesh = try? STLMesh.read(from: url),
                      edgeImprovementAvailable(mesh.edgeDesignCheck(), extent: mesh.maximum - mesh.minimum) else { return nil }
                return mesh
            }.value
            guard !Task.isCancelled else { return }
            edgeEditableMesh = mesh
        }
    }
}

/// The next-action bar's status line. `actionStatus` covers a missing material, quantity or stock before this.
func nextStepStatusText(_ step: ModelsNextStep) -> String {
    switch step {
    case .needsSetup: return "Connect your account to upload and estimate."
    case .needsPlatform: return "Choose or create a platform to upload and order."
    case .needsModel: return "Import a model to get started."
    case .uploading: return "Uploading your model…"
    case .needsUpload: return "Upload this model to request an estimate."
    case .needsEstimate: return "Get an estimate for this material and quantity."
    case .estimateStale: return "The configuration has changed. Get a new estimate."
    case .readyForDraft: return "Your estimate is ready. Create an order draft when you’re set."
    }
}

/// What the next-action bar offers while no platform is chosen: create the first one directly when the account has
/// none, otherwise choose one in Settings (also where platforms load if they haven't yet).
enum PlatformSetupAction: Equatable {
    case createPlatform, chooseInSettings
}

func platformSetupAction(platformsLoaded: Bool, platformCount: Int) -> PlatformSetupAction {
    platformsLoaded && platformCount == 0 ? .createPlatform : .chooseInSettings
}

func platformSetupStatus(_ action: PlatformSetupAction) -> String {
    switch action {
    case .createPlatform: return "Create a platform to upload models and place orders."
    case .chooseInSettings: return "Choose a default platform in Settings to upload models and place orders."
    }
}

/// The Material picker's sections: one per type, in `filamentTypes` order, keeping the catalog order within each.
struct MaterialPickerSection {
    let type: String
    let materials: [Record]
}

func materialPickerSections(_ filaments: [Record]) -> [MaterialPickerSection] {
    filamentTypes(in: filaments).map { MaterialPickerSection(type: $0, materials: filamentsMatching(filaments, type: $0)) }
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

// MARK: - Upload from URL

struct ImportFromURLSheet: View {
    @EnvironmentObject var store: StudioStore
    @Environment(\.dismiss) private var dismiss
    @State private var url = ""
    @State private var name = ""
    @State private var validation: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Upload from URL").font(.title2.weight(.bold))
                Text("Slant fetches the model from this link straight into your Slant account. It isn’t added to your library on this Mac.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(24)
            Divider()
            Form {
                TextField("Link", text: $url, prompt: Text("https://…"))
                TextField("Name", text: $name, prompt: Text("Model name in Slant"))
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
                // No Return shortcut: no keyboard shortcut may upload (AGENTS.md); uploading takes a click.
                Button("Upload") { importModel() }
                    .buttonStyle(.borderedProminent)
                    .disabled(store.busy || !store.hasKey)
            }
            .padding(20)
        }
        .frame(width: 480, height: 350)
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

/// The estimate's breakdown under the headline total. Left out on purpose:
/// - `estimatedPrintTime` and `totalMaterial`: the OpenAPI gives no unit, and live values don't match Model analysis
///   (6.66 against 402 minutes for the same 3MF), so any unit would be a guess. Model analysis on the same screen shows
///   the documented print time (minutes) and weight (grams).
/// - `subtotal` ("before surcharges"): live replies differ from the price per unit even with no surcharges (7.64
///   against 9.93), so listing it beside the total reads as a contradiction.
/// Surcharges, which `total` includes, are listed only when one is charged.
/// `bodyCount` is Slant's `metrics.bodyCount` for the estimated file, when known; it names the body charge.
func estimateRows(_ estimate: [String: Any], bodyCount: Int? = nil) -> [(String, String)] {
    var rows: [(String, String)] = []
    if estimate["pricePerUnit"] != nil { rows.append(("Price per unit", money(estimate["pricePerUnit"]))) }
    if let quantity = estimate["quantity"] { rows.append(("Quantity", String(describing: quantity))) }
    if estimateAmountIsCharged(estimate["bodyChargeCost"]) { rows.append((estimateBodyChargeLabel(bodyCount: bodyCount), money(estimate["bodyChargeCost"]))) }
    if estimateAmountIsCharged(estimate["oversizeSurcharge"]) { rows.append(("Oversize fee", money(estimate["oversizeSurcharge"]))) }
    if estimate["total"] != nil { rows.append(("Total", money(estimate["total"]))) }
    return rows
}

/// True for an amount above zero, and for a present value that can't be read (shown as "—" rather than hidden).
func estimateAmountIsCharged(_ value: Any?) -> Bool {
    guard let value, !(value is NSNull) else { return false }
    let decimal: Decimal?
    if let number = value as? NSNumber { decimal = number.decimalValue }
    else if let string = value as? String {
        decimal = Decimal(string: string.trimmingCharacters(in: .whitespaces), locale: Locale(identifier: "en_US_POSIX"))
    } else { decimal = nil }
    guard let decimal else { return true }
    return decimal > 0
}

func displayedEstimateRows(_ estimate: [String: Any], bodyCount: Int? = nil) -> [(String, String)] {
    estimateRows(estimate, bodyCount: bodyCount).filter { $0.0 != "Total" && $0.0 != "Quantity" }
}

/// "Charge for 9 extra bodies" when Slant's body count for the file is known and above one, else a plain name.
func estimateBodyChargeLabel(bodyCount: Int?) -> String {
    guard let bodyCount, bodyCount > 1 else { return "Charge for extra bodies" }
    let extra = bodyCount - 1
    return "Charge for \(extra.formatted()) extra \(extra == 1 ? "body" : "bodies")"
}

/// The body count to name the estimate's body charge with: only from the file the estimate was made for
/// (`estimateContext` starts with its file ID), so a previous file's estimate never borrows another file's count.
func estimateBodyCount(estimateContext: String, file: Record?) -> Int? {
    guard let file, let estimated = estimateContext.split(separator: "|", omittingEmptySubsequences: false).first,
          !estimated.isEmpty, String(estimated) == file.id else { return nil }
    return slantBodyCount(file.metrics)
}

/// Slant's `metrics.bodyCount` as a whole number of at least 1; nil when absent, null, fractional or unreadable.
func slantBodyCount(_ metrics: [String: Any]) -> Int? {
    let value: Double
    if let number = metrics["bodyCount"] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() { value = number.doubleValue }
    else if let text = metrics["bodyCount"] as? String, let parsed = Double(text.trimmingCharacters(in: .whitespaces)) { value = parsed }
    else { return nil }
    guard value.isFinite, value >= 1, value <= 1_000_000, value == value.rounded() else { return nil }
    return Int(value)
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
    ["x": "Width", "y": "Depth", "z": "Height", "weight": "Weight", "volume": "Volume", "bodyCount": "Bodies", "printTimeEstimate": "Print time",
     "supportRequired": "Needs supports", "supportVolumeEstimate": "Support volume (est.)"][key] ?? key
}

func metricUnit(_ key: String, _ metrics: [String: Any]) -> String {
    if key == "weight" {
        if let unit = metrics["weightUnit"] as? String, !unit.isEmpty { return displayUnit(unit) }
    }
    if let unit = (metrics["units"] as? [String: String])?[key], !unit.trimmingCharacters(in: .whitespaces).isEmpty {
        return displayUnit(unit)
    }
    return ["x": "mm", "y": "mm", "z": "mm", "weight": "g", "volume": "cm³", "printTimeEstimate": "min",
            "surfaceArea": "mm²", "supportVolumeEstimate": "cm³"][key]
        ?? ""
}

/// Slant's `units` write powers as plain digits ("cm3", "mm2"); shows them with superscripts. Others pass through.
func displayUnit(_ unit: String) -> String {
    let trimmed = unit.trimmingCharacters(in: .whitespaces)
    let superscripts: [String: String] = [
        "mm2": "mm²", "cm2": "cm²", "m2": "m²", "in2": "in²", "mm^2": "mm²", "cm^2": "cm²",
        "mm3": "mm³", "cm3": "cm³", "m3": "m³", "in3": "in³", "mm^3": "mm³", "cm^3": "cm³",
    ]
    return superscripts[trimmed.lowercased()] ?? trimmed
}

/// True when a `printTimeEstimate` unit means minutes (the OpenAPI's documented unit, used when none is given).
func isMinutesUnit(_ unit: String) -> Bool {
    ["min", "mins", "minute", "minutes"].contains(unit.trimmingCharacters(in: .whitespaces).lowercased())
}

/// Minutes as "45 min" under an hour and "6 h 42 min" (or "2 h") from an hour, rounded to the nearest minute.
/// Nil for values that aren't a finite, non-negative number.
func formattedPrintMinutes(_ value: Any?) -> String? {
    let minutes: Double
    if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() { minutes = number.doubleValue }
    else if let text = value as? String, let parsed = Double(text.trimmingCharacters(in: .whitespaces)) { minutes = parsed }
    else { return nil }
    guard minutes.isFinite, minutes >= 0, minutes < 100_000_000 else { return nil }
    let total = Int(minutes.rounded())
    if total == 0 && minutes > 0 { return "Under 1 min" }
    if total < 60 { return "\(total) min" }
    let hours = total / 60, rest = total % 60
    return rest == 0 ? "\(hours) h" : "\(hours) h \(rest) min"
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
        if key == "printTimeEstimate", isMinutesUnit(unit), let formatted = formattedPrintMinutes(metrics[key]) {
            return (key, metricName(key), formatted)
        }
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
    let name = materialDisplayName(displayName(for: record, fallback: "Untitled material"))
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
    // The Component schema sends `weight` as a number with a separate `weightUnit` ("g").
    if let number = catalogNumberText(record.values["weight"]), let unit = record.string("weightUnit").nilIfEmpty {
        rows.append(("Weight", "\(number) \(unit)"))
    } else if !weight.isEmpty { rows.append(("Weight", weight)) }
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
    if !trimmedURL.lowercased().hasPrefix("https://") { return "Use an https:// link to upload a model." }
    if trimmedName.isEmpty { return "Enter a name for the uploaded model." }
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
        let categories = kind == .components ? store.componentCategories : []
        return typed.filter { catalogRecordMatches($0, search: search, categories: categories) }
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
                            .accessibilityLabel(catalogRecordTitle(row.record, kind: kind))
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
                Text(catalogRecordTitle(record, kind: kind))
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
        case .stationery:
            return stationeryCardSubtitle(record)
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
                    Text(catalogRecordTitle(record, kind: kind)).font(.title2.weight(.bold))
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
                }.studioDisclosureStyle()
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
    if kind == .stationery {
        ForEach(stationeryFactRows(record), id: \.0) { row in
            LabeledContent(row.0, value: row.1)
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
    if kind != .materials, !color.isEmpty { LabeledContent("Colour", value: color) }
}

/// `categories` lets a component match its category's name (see `catalogSearchFields`, CatalogDisplay.swift).
func catalogRecordMatches(_ record: Record, search: String, categories: [Record] = []) -> Bool {
    let trimmed = search.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return true }
    return catalogSearchFields(record, categories: categories).contains { $0.localizedCaseInsensitiveContains(trimmed) }
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
