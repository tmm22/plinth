import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - Design an Accessory from a Photo: the sheet
//
// Opened from File › Design an Accessory from a Photo… and the Models Import menu (`StudioStore.showAccessoryDesigner`).
// The brief (photos, description, measurements, notes) and the whole conversation live in this sheet's state and go
// when it closes. Nothing is sent until Start Design (after the one-time photo-sharing consent for Anthropic), and
// nothing is uploaded to Slant: Save to Library and Save Template… are local.

let accessoryInstallOpenSCADURL = URL(string: "https://openscad.org/downloads.html")!

/// Studio's own checks of a render, for the seller, most important first.
func accessoryStudioCheckLines(_ facts: AccessoryRenderFacts) -> [String] {
    var lines: [String] = []
    let size = facts.sizeMM
    lines.append("Size: \(String(format: "%.1f", size.x)) × \(String(format: "%.1f", size.y)) × \(String(format: "%.1f", size.z)) mm (W × D × H)")
    lines.append("Mesh check: \(meshHealthSummary(facts.health).title)")
    lines.append(facts.fitsBuildVolume ? "Fits Slant’s \(Int(slantBuildVolumeMM)) mm build volume"
                                       : "Too big for Slant’s \(Int(slantBuildVolumeMM)) mm build volume")
    if !facts.sitsOnBed { lines.append("Not on the bed: the lowest point is at Z = \(String(format: "%.1f", facts.lowestZ)) mm") }
    lines.append("Flat contact with the bed: \(Int(facts.contactAreaMM2.rounded()).formatted()) mm²")
    if let wall = facts.wallThickness {
        lines.append(wall.line)
        lines.append(contentsOf: wall.details)
    }
    lines.append(facts.customizerValues.isEmpty
                 ? "No values to adjust were found, so Personalise from Template can’t change this design’s sizes"
                 : "\(facts.customizerValues.count) values you can adjust later in Personalise from Template")
    let warnings = facts.openSCADMessages.filter { $0.uppercased().hasPrefix("WARNING") }.count
    if warnings > 0 { lines.append(warnings == 1 ? "OpenSCAD reported 1 warning" : "OpenSCAD reported \(warnings) warnings") }
    return lines
}

/// The status line under the conversation: replies and renders used this round, and what has been spent.
func accessoryProgressLine(repliesThisRound: Int, rendersThisRound: Int, limits: AccessoryDesignLimits) -> String {
    "Reply \(repliesThisRound) of \(limits.maxReplies) · render \(rendersThisRound) of \(limits.maxRenders) this round"
}

struct AccessoryPhoto: Identifiable {
    let id = UUID()
    let image: PreparedImage
    let preview: NSImage?
}

struct AccessoryDesignerSheet: View {
    @EnvironmentObject var store: StudioStore
    @ObservedObject private var anthropic = AnthropicConnection.shared
    @State private var brief = AccessoryDesignBrief()
    @State private var photos: [AccessoryPhoto] = []
    @State private var preparingPhotos = 0
    @State private var photoProblem: String?
    @State private var openSCAD: URL?
    @State private var lookedForOpenSCAD = false
    @State private var startProblem: String?
    @State private var consentRequest: ImageSharingConsentRequest?
    @State private var run: AccessoryDesignRun?
    @State private var confirmClose = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Design an accessory from a photo").font(.title2.weight(.bold))
                Text("Claude writes an OpenSCAD design from your photos and measurements. Studio renders and checks each version on this Mac, and you decide what to save.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(24)
            Divider()
            if let run {
                // A fresh view per run, so a saved-name or saved state never carries over after Start Over.
                AccessoryDesignRunView(run: run, brief: brief, startOver: { self.run = nil }, close: requestClose)
                    .id(ObjectIdentifier(run))
            } else {
                briefForm
                Divider()
                briefFooter
            }
        }
        .frame(minWidth: 820, idealWidth: 960, minHeight: 620, idealHeight: 760)
        .onAppear { if !lookedForOpenSCAD { lookForOpenSCAD() } }
        .onDisappear { run?.stop() }
        .confirmationDialog("Close and discard this design?", isPresented: $confirmClose, titleVisibility: .visible) {
            Button("Discard", role: .destructive) { close() }
            Button("Keep Working", role: .cancel) {}
        } message: {
            Text("Studio doesn’t keep the photos, the conversation or designs you haven’t saved.")
        }
    }

    private func lookForOpenSCAD() {
        openSCAD = installedOpenSCADExecutable()
        lookedForOpenSCAD = true
    }

    private func requestClose() {
        if run?.hasStarted == true { confirmClose = true } else { close() }
    }

    private func close() {
        if let run, run.isWorking {
            // The round's own entry can't be written once the sheet has gone, so record what was spent now.
            store.activities.insert(Activity(title: "Design an accessory", detail: "Closed while working · "
                + accessoryRunSummary(replies: run.totalReplies, renders: run.totalRenders, cost: run.cost, costMayBeHigher: true),
                success: false), at: 0)
        }
        run?.stop()
        store.showAccessoryDesigner = false
    }

    // MARK: Brief

    private var briefForm: some View {
        Form {
            Section {
                photoStrip
                HStack {
                    Button("Choose Photos…") { choosePhotos() }
                        .disabled(photos.count + preparingPhotos >= accessoryMaximumPhotos)
                    Text("Or drop up to \(accessoryMaximumPhotos) JPEG, PNG or HEIC photos here.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let photoProblem {
                    Label(photoProblem, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } header: {
                Text("Photos")
            } footer: {
                Text("Show the object the accessory is for, from the angles that matter. Photos are resized and their location and camera details are removed before sending.")
                    .settingsFooterLayout()
            }
            Section("What to make") {
                TextField("Accessory", text: $brief.description, prompt: Text("A stand that holds this phone at 60°"), axis: .vertical)
                    .lineLimit(2...4)
                    .labelsHidden()
                    .accessibilityLabel("What to make")
            }
            Section {
                ForEach($brief.measurements) { $row in
                    measurementRow($row)
                }
                Button("Add Measurement") { brief.measurements.append(AccessoryMeasurement()) }
                    .disabled(brief.measurements.count >= accessoryMaximumMeasurements)
            } header: {
                Text("Measurements")
            } footer: {
                Text("A photo has no scale, so Claude takes every size from these. Say how you measured: Claude adds more clearance for a rough measurement.")
                    .settingsFooterLayout()
            }
            Section("Notes") {
                TextField("Notes", text: $brief.notes, prompt: Text("Optional: material, where it will be used, anything to avoid"), axis: .vertical)
                    .lineLimit(2...5)
                    .labelsHidden()
                    .accessibilityLabel("Notes")
            }
            prerequisitesSection
        }
        .formStyle(.grouped)
        .dropDestination(for: URL.self) { urls, _ in
            addPhotos(urls)
            return true
        }
    }

    @ViewBuilder
    private var photoStrip: some View {
        if photos.isEmpty && preparingPhotos == 0 {
            Text("No photos yet").foregroundStyle(.secondary)
        } else {
            ScrollView(.horizontal) {
                HStack(spacing: 10) {
                    ForEach(photos) { photo in
                        ZStack(alignment: .topTrailing) {
                            Group {
                                if let preview = photo.preview {
                                    Image(nsImage: preview).resizable().scaledToFill()
                                } else {
                                    Color.secondary.opacity(0.2)
                                }
                            }
                            .frame(width: 120, height: 90)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            Button {
                                photos.removeAll { $0.id == photo.id }
                            } label: {
                                Image(systemName: "xmark.circle.fill").symbolRenderingMode(.hierarchical)
                            }
                            .buttonStyle(.plain)
                            .padding(4)
                            .accessibilityLabel("Remove Photo")
                        }
                    }
                    if preparingPhotos > 0 {
                        ProgressView().controlSize(.small).frame(width: 120, height: 90)
                    }
                }
            }
        }
    }

    private func measurementRow(_ row: Binding<AccessoryMeasurement>) -> some View {
        HStack(spacing: 8) {
            TextField("Measurement", text: row.label, prompt: Text("Phone thickness"))
                .labelsHidden()
                .accessibilityLabel("Measurement name")
            TextField("Millimetres", text: row.millimetres, prompt: Text("mm"))
                .labelsHidden()
                .accessibilityLabel("Size in millimetres")
                .frame(width: 80)
            Picker("How measured", selection: row.method) {
                ForEach(AccessoryMeasurementMethod.allCases) { method in Text(method.title).tag(method) }
            }
            .labelsHidden()
            .accessibilityLabel("How measured")
            .frame(width: 170)
            Button {
                let id = row.wrappedValue.id
                brief.measurements.removeAll { $0.id == id }
                if brief.measurements.isEmpty { brief.measurements.append(AccessoryMeasurement()) }
            } label: {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Remove Measurement")
        }
    }

    private var prerequisitesSection: some View {
        Section {
            if anthropic.isConfigured {
                Label("Claude (Anthropic) is set up.", systemImage: "checkmark.circle").foregroundStyle(.secondary)
            } else {
                HStack {
                    Label("Add your Anthropic API key in Settings › Account › Claude (Anthropic).", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                    Spacer()
                    Button("Open Settings") { store.requestSettings(.account) }
                }
            }
            if openSCAD != nil {
                Label("OpenSCAD is installed; Studio renders each design with it on this Mac.", systemImage: "checkmark.circle")
                    .foregroundStyle(.secondary)
            } else if lookedForOpenSCAD {
                VStack(alignment: .leading, spacing: 6) {
                    Label("OpenSCAD isn’t installed in Applications. Studio needs it to render each design on this Mac.", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                    HStack {
                        Link("Install OpenSCAD", destination: accessoryInstallOpenSCADURL)
                        Button("Check Again") { lookForOpenSCAD() }
                            .help("Looks for OpenSCAD in Applications again, after you install it.")
                    }
                }
            }
        } header: {
            Text("Before you start")
        } footer: {
            Text(costForecastText).settingsFooterLayout()
        }
    }

    private var costForecastText: String {
        let forecast = accessoryCostForecast(photoSizes: photos.map { ($0.image.pixelWidth, $0.image.pixelHeight) },
                                             textCharacters: accessoryFirstTurnText(brief, photoCount: max(1, photos.count)).count)
        return accessoryCostForecastText(forecast)
            + " Each round allows \(AccessoryDesignLimits().maxReplies) replies and \(AccessoryDesignLimits().maxRenders) renders; Studio never resends a request by itself."
    }

    private var blockedReason: String? {
        if !anthropic.isConfigured { return "Add your Anthropic API key in Settings first." }
        if openSCAD == nil { return "Install OpenSCAD first." }
        if preparingPhotos > 0 { return "Preparing photos…" }
        return accessoryBriefProblem(brief, photoCount: photos.count)
    }

    private var briefFooter: some View {
        HStack(spacing: 12) {
            if let problem = startProblem ?? blockedReason {
                Text(problem).font(.callout).foregroundStyle(.secondary).lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            // Escape too; once anything has been sent, closing asks first.
            Button("Close") { requestClose() }
                .keyboardShortcut(.cancelAction)
            // Never the default button and no shortcut: every request is billed.
            Button("Start Design") { startDesign() }
                .buttonStyle(.borderedProminent)
                .disabled(blockedReason != nil)
        }
        .padding(20)
        // Asks once before the first photo goes to Anthropic; Don't Send is the default.
        .imageSharingConsent($consentRequest)
    }

    // MARK: Photos

    private func choosePhotos() {
        let panel = NSOpenPanel()
        panel.message = "Choose up to \(accessoryMaximumPhotos) photos of the object the accessory is for."
        panel.allowedContentTypes = [.jpeg, .png, .heic]
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        addPhotos(panel.urls)
    }

    private func addPhotos(_ urls: [URL]) {
        let room = accessoryMaximumPhotos - photos.count - preparingPhotos
        guard room > 0 else { photoProblem = "Use at most \(accessoryMaximumPhotos) photos."; return }
        photoProblem = urls.count > room ? "Only the first \(room == 1 ? "photo was" : "\(room) photos were") added: use at most \(accessoryMaximumPhotos)." : nil
        for url in urls.prefix(room) {
            preparingPhotos += 1
            Task { @MainActor in
                let result = await Task.detached(priority: .userInitiated) {
                    Result { try prepareImageForSharing(at: url, maxLongEdge: imagePreparationClaudeLongEdge) }
                }.value
                preparingPhotos -= 1
                switch result {
                case .success(let image):
                    guard photos.count < accessoryMaximumPhotos, run == nil else { return }
                    photos.append(AccessoryPhoto(image: image, preview: NSImage(data: image.data)))
                case .failure(let error):
                    photoProblem = error.localizedDescription
                }
            }
        }
    }

    // MARK: Start

    private func startDesign() {
        startProblem = nil
        guard blockedReason == nil, run == nil else { return }
        runWithImageSharingConsent(.anthropic, request: $consentRequest) { begin() }
    }

    private func begin() {
        guard run == nil, blockedReason == nil, let executable = openSCAD else { return }
        // OpenSCAD may have been removed since it was found.
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            openSCAD = nil
            startProblem = "OpenSCAD is no longer in Applications. Install it again, then press Check Again."
            return
        }
        let newRun = AccessoryDesignRun(
            send: { request, progress in try await AnthropicConnection.shared.send(request, onProgress: progress) },
            render: { code in try await renderAccessoryDesign(code: code, executable: executable) })
        run = newRun
        newRun.start(firstTurn: accessoryFirstTurn(brief, photos: photos.map(\.image)))
    }
}

// MARK: - The conversation and result

private struct AccessoryDesignRunView: View {
    @EnvironmentObject var store: StudioStore
    @ObservedObject var run: AccessoryDesignRun
    let brief: AccessoryDesignBrief
    let startOver: () -> Void
    let close: () -> Void
    @State private var answer = ""
    @State private var note = ""
    @State private var libraryName = ""
    @State private var savedRenderIDs: Set<UUID> = []
    @State private var saveStatus: String?
    @State private var saveProblem: String?
    @State private var saving = false

    var body: some View {
        HSplitView {
            conversation
                .frame(minWidth: 360, idealWidth: 420)
            preview
                .frame(minWidth: 380)
        }
        .onChange(of: run.phase) { old, new in
            logActivityIfRoundEnded(from: old, to: new)
            if new == .finished, let finish = run.finish {
                libraryName = accessoryLibraryName(suggested: finish.name, description: brief.description)
                saveStatus = nil
                saveProblem = nil
            }
        }
    }

    // MARK: Conversation

    private var conversation: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(run.transcript) { entry in
                            transcriptRow(entry).id(entry.id)
                        }
                    }
                    .padding(16)
                }
                .onChange(of: run.transcript.count) {
                    if let last = run.transcript.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } }
                }
            }
            Divider()
            conversationFooter
                .padding(16)
        }
    }

    @ViewBuilder
    private func transcriptRow(_ entry: AccessoryTranscriptEntry) -> some View {
        switch entry.kind {
        case .claude(let text):
            Label { Text(text).textSelection(.enabled).fixedSize(horizontal: false, vertical: true) } icon: { Image(systemName: "sparkles") }
        case .render(_, _, let line, let acceptable):
            Label(line, systemImage: acceptable ? "cube" : "exclamationmark.triangle")
                .foregroundStyle(acceptable ? Color.primary : Color.orange)
                .fixedSize(horizontal: false, vertical: true)
        case .renderFailed(let number, let text):
            Label("Render \(number) failed: \(text)", systemImage: "xmark.octagon")
                .foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
        case .refusedCode(let text):
            Label("Studio didn’t run Claude’s code: \(text)", systemImage: "hand.raised")
                .foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
        case .question(let text):
            Label { Text(text).bold().fixedSize(horizontal: false, vertical: true) } icon: { Image(systemName: "questionmark.bubble") }
        case .answer(let text):
            Label("You: \(text)", systemImage: "person").foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        case .seller(let text):
            Label("You: \(text)", systemImage: "person").foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        case .notice(let text):
            Label(text, systemImage: "info.circle").foregroundStyle(.secondary).font(.callout)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var conversationFooter: some View {
        VStack(alignment: .leading, spacing: 10) {
            switch run.phase {
            case .working(let status):
                HStack {
                    ProgressView().controlSize(.small)
                    Text(status).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                    Spacer()
                    Button("Stop") { run.stop() }
                }
            case .waitingForSeller:
                Text(run.pendingQuestion ?? "").font(.callout.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
                TextField("Answer", text: $answer, prompt: Text("Your answer"), axis: .vertical)
                    .lineLimit(1...4)
                    .labelsHidden()
                    .accessibilityLabel("Answer to Claude’s question")
                HStack {
                    Spacer()
                    Button("Skip") { send(answer: nil) }
                    Button("Send Answer") { send(answer: answer) }
                        .disabled(answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            default:
                if run.canSendNote {
                    TextField("Note to Claude", text: $note,
                              prompt: Text(run.phase == .finished ? "Ask for changes, such as “make the lip 2 mm taller”" : "Tell Claude how to continue"),
                              axis: .vertical)
                        .lineLimit(1...4)
                        .labelsHidden()
                        .accessibilityLabel("Note to Claude")
                }
                HStack {
                    if case .stopped = run.phase {
                        Button("Start Over") { startOver() }
                            .help("Back to your photos and measurements, to change them and start a new design.")
                    }
                    Spacer()
                    if run.canTryAgain {
                        Button("Try Again") { run.tryAgain() }
                            .help("Sends the same request again. It is billed again.")
                    }
                    if run.canSendNote {
                        Button("Send to Claude") { sendNote() }
                            .disabled(run.messages.last?.role == .assistant && note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            .help("Starts another round of up to \(run.limits.maxReplies) replies and \(run.limits.maxRenders) renders.")
                    }
                }
            }
            HStack(alignment: .firstTextBaseline) {
                Text(accessoryRunSummary(replies: run.totalReplies, renders: run.totalRenders, cost: run.cost, costMayBeHigher: run.costMayBeHigher))
                if run.isWorking {
                    Text("· " + accessoryProgressLine(repliesThisRound: run.repliesThisRound, rendersThisRound: run.rendersThisRound, limits: run.limits))
                }
            }
            .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                // Escape too; the sheet asks before discarding anything.
                Button("Close") { close() }
                    .keyboardShortcut(.cancelAction)
            }
        }
    }

    private func send(answer text: String?) {
        run.answer(text)
        answer = ""
    }

    private func sendNote() {
        let text = note
        note = ""
        if run.canTryAgain && text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { run.tryAgain() } else { run.sendNote(text) }
    }

    // MARK: Preview and result

    private var preview: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let render = run.finish?.render ?? run.latestRender {
                    // A new view per render: the scene is built once per view.
                    STLSceneView(mesh: render.mesh, showsPrintBed: true)
                        .id(render.id)
                        .frame(minHeight: 260, idealHeight: 320)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .accessibilityLabel("3D preview of the latest render")
                    if let finish = run.finish, run.phase == .finished {
                        resultSection(finish)
                    }
                    checksSection(render)
                } else {
                    ContentUnavailableView("No render yet", systemImage: "cube.transparent",
                                           description: Text("Each version Claude writes is rendered with OpenSCAD on this Mac and shown here."))
                        .frame(minHeight: 260)
                }
            }
            .padding(16)
        }
    }

    private func checksSection(_ render: AccessoryRender) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Studio’s checks").font(.headline)
            ForEach(Array(accessoryStudioCheckLines(render.facts).enumerated()), id: \.offset) { _, line in
                Text(line).font(.callout).fixedSize(horizontal: false, vertical: true)
            }
            if !render.problems.isEmpty {
                Label(render.problems.joined(separator: " "), systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange).font(.callout).fixedSize(horizontal: false, vertical: true)
            }
            Text("Advisory only: these checks and Claude’s notes can’t tell how strong a part will be. Test-print it before selling.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func resultSection(_ finish: AccessoryFinish) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Claude’s design").font(.headline)
            if !finish.summary.isEmpty { Text(finish.summary).textSelection(.enabled).fixedSize(horizontal: false, vertical: true) }
            if !finish.printOrientation.isEmpty {
                LabeledContent("Print orientation") { Text(finish.printOrientation).fixedSize(horizontal: false, vertical: true) }
            }
            if !finish.notes.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(finish.notes.enumerated()), id: \.offset) { _, line in
                        Label(line, systemImage: "circle.fill").labelStyle(AccessoryBulletLabelStyle())
                    }
                }
            }
            TextField("Library name", text: $libraryName)
                .accessibilityLabel("Library name")
            HStack {
                Button("Save Template…") { saveTemplate(finish) }
                    .help("Saves the OpenSCAD file, which you can adjust later in Personalise from Template.")
                Spacer()
                if savedRenderIDs.contains(finish.render.id) {
                    Label("Saved", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                } else {
                    Button("Save to Library") { saveToLibrary(finish) }
                        .buttonStyle(.borderedProminent)
                        .disabled(saving || libraryNameProblem != nil)
                }
            }
            if let message = saveProblem ?? libraryNameProblem {
                Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let saveStatus {
                Label(saveStatus, systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.callout)
            }
        }
    }

    private var libraryNameProblem: String? {
        let trimmed = libraryName.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "Enter a name for the library." }
        if trimmed.count > maximumModelNameLength { return "Use a name of \(maximumModelNameLength) characters or fewer." }
        return nil
    }

    private func saveToLibrary(_ finish: AccessoryFinish) {
        guard !saving, libraryNameProblem == nil, !savedRenderIDs.contains(finish.render.id) else { return }
        saving = true
        saveProblem = nil
        let name = libraryName.trimmingCharacters(in: .whitespacesAndNewlines)
        let stl = finish.render.stl
        let fileName = exportFileName(modelName: name, fileExtension: "stl")
        Task { @MainActor in
            defer { saving = false }
            let written = await Task.detached(priority: .userInitiated) { () -> Result<URL, Error> in
                Result {
                    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("\(accessoryTempFolderPrefix)\(UUID().uuidString)")
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    let url = folder.appendingPathComponent(fileName)
                    do { try stl.write(to: url, options: .atomic) } catch { try? FileManager.default.removeItem(at: folder); throw error }
                    return url
                }
            }.value
            switch written {
            case .success(let url):
                defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
                // importModel shows its own alert when copying into the library fails.
                guard store.importModel(url) else { saveProblem = "The design couldn’t be added to your library."; return }
                savedRenderIDs.insert(finish.render.id)
                saveStatus = "Saved “\(name)” to your library."
                store.activities.insert(Activity(title: "Design an accessory", detail: "Saved a new model", success: true), at: 0)
            case .failure(let error):
                saveProblem = error.localizedDescription
            }
        }
    }

    private func saveTemplate(_ finish: AccessoryFinish) {
        let name = libraryName.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = name.replacingOccurrences(of: #"\s*\(designed\)$"#, with: "", options: .regularExpression)
        let panel = NSSavePanel()
        panel.message = "Save the OpenSCAD design. Open it later with Personalise from Template to adjust its sizes."
        panel.allowedContentTypes = [UTType(filenameExtension: "scad") ?? .plainText]
        panel.nameFieldStringValue = exportFileName(modelName: base.isEmpty ? "Accessory" : base, fileExtension: "scad")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try Data(accessoryTemplateFileText(code: finish.render.code, name: base).utf8).write(to: url, options: .atomic)
            saveProblem = nil
            saveStatus = "Saved the template as “\(url.lastPathComponent)”."
        } catch {
            saveProblem = "The template couldn’t be saved: \(error.localizedDescription)"
        }
    }

    /// One Activity entry when a round ends: counts, cost and status only.
    private func logActivityIfRoundEnded(from old: AccessoryDesignPhase, to new: AccessoryDesignPhase) {
        // Closing while working records its own entry (AccessoryDesignerSheet.close).
        guard case .working = old, store.showAccessoryDesigner else { return }
        let summary = accessoryRunSummary(replies: run.totalReplies, renders: run.totalRenders, cost: run.cost, costMayBeHigher: run.costMayBeHigher)
        switch new {
        case .finished:
            store.activities.insert(Activity(title: "Design an accessory", detail: "Finished · \(summary)", success: true), at: 0)
        case .stopped:
            store.activities.insert(Activity(title: "Design an accessory", detail: (run.refused ? "Claude declined · " : "Stopped · ") + summary, success: false), at: 0)
        default:
            break
        }
    }
}

private struct AccessoryBulletLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            configuration.icon.font(.system(size: 5)).foregroundStyle(.secondary)
            configuration.title.fixedSize(horizontal: false, vertical: true)
        }
    }
}

extension StudioStore {
    /// File › Design an Accessory from a Photo…: opens the sheet. Does nothing while a sheet, alert or dialog is open.
    /// Nothing is sent until Start Design.
    func openAccessoryDesignerFromMenu() {
        guard !menuCommandsBlockedByModalUI else { return }
        showAccessoryDesigner = true
    }
}
