import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - Design an Accessory from a Photo: the sheet
//
// Opened from File › Design an Accessory from a Photo… and the Models Import menu (`StudioStore.showAccessoryDesigner`).
// The brief (photos, description, measurements, notes) and the whole conversation live in this sheet's state and go
// when it closes. Nothing is sent until Suggest Accessories or Start Design (after the one-time photo-sharing consent
// for Anthropic, which covers both), and nothing is uploaded to Slant: Save to Library and Save Template… are local.
// The suggested ideas (AccessorySuggestions.swift) live in this sheet's memory too, and survive Start Over.

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
    if facts.overhang.overhangAreaMM2 <= 0 || facts.overhangLocation == nil {
        lines.append("Overhangs: none steeper than 45° from vertical")
    } else if facts.hasNotableOverhangs, let location = facts.overhangLocation {
        let low = String(format: "%.0f", location.lowestZ), high = String(format: "%.0f", location.highestZ)
        let place = low == high ? "at \(low) mm up" : "between \(low) and \(high) mm up"
        lines.append("Overhangs: \(percentLabel(facts.overhang.fraction)) of the surface faces down more steeply than 45°, \(place); "
                     + "it may need supports. Ask Claude to fix them")
    } else {
        lines.append("Overhangs: small (under \(percentLabel(accessoryOverhangNotableShare)) of the surface steeper than 45°)")
    }
    lines.append(facts.customizerValues.isEmpty
                 ? "No values to adjust were found, so Personalise from Template can’t change this design’s sizes"
                 : "\(facts.customizerValues.count) values you can adjust later in Personalise from Template")
    let warnings = facts.openSCADMessages.filter { $0.uppercased().hasPrefix("WARNING") }.count
    if warnings > 0 { lines.append(warnings == 1 ? "OpenSCAD reported 1 warning" : "OpenSCAD reported \(warnings) warnings") }
    return lines
}

/// The seller's typed measurements, as shown beside the design's fit sizes: "Phone thickness: 9.5 mm (calipers)".
func accessoryTypedMeasurementLines(_ rows: [AccessoryMeasurement]) -> [String] {
    rows.compactMap { row in
        let label = row.label.split(whereSeparator: \.isNewline).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        guard !label.isEmpty, let value = meshFitMillimetres(row.millimetres) else { return nil }
        let method: String
        switch row.method {
        case .calipers: method = "calipers"
        case .ruler: method = "ruler"
        case .estimate: method = "estimate"
        }
        return "\(label): \(accessoryMillimetresText(value)) (\(method))"
    }
}

/// The design's fit sizes for the seller, or a line saying it reported none.
func accessoryFitSizeLines(_ fitSizes: [AccessoryFitSize]) -> [String] {
    fitSizes.isEmpty
        ? ["This version didn’t report its fit sizes. Ask Claude to echo each size that must fit."]
        : fitSizes.map(accessoryFitSizeText)
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
    /// The Claude key stays locked while this sheet is open (`AnthropicConnection.beginSession`); balanced exactly once.
    @State private var claudeSessionOpen = false
    /// The seller's "What is it?" for Suggest Accessories. Memory only.
    @State private var objectHint = ""
    @StateObject private var suggestions = AccessorySuggestionRun(
        send: { request, progress in try await AnthropicConnection.shared.send(request, onProgress: progress) })
    /// The idea waiting for Replace / Keep Current Details.
    @State private var pendingIdea: AccessoryIdea?
    @State private var ideaNotice: String?

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
        .onAppear {
            if !claudeSessionOpen {
                claudeSessionOpen = true
                AnthropicConnection.shared.beginSession()
            }
            if !lookedForOpenSCAD { lookForOpenSCAD() }
        }
        .onDisappear {
            run?.stop()
            suggestions.stop()
            if claudeSessionOpen {
                claudeSessionOpen = false
                AnthropicConnection.shared.endSession()
            }
        }
        .confirmationDialog(closeConfirmation?.title ?? "Close this window?", isPresented: $confirmClose, titleVisibility: .visible) {
            Button("Discard", role: .destructive) { close() }
            Button("Keep Working", role: .cancel) {}
        } message: {
            Text(closeConfirmation?.message ?? "Studio doesn’t keep the photos or anything you haven’t saved.")
        }
    }

    private func lookForOpenSCAD() {
        openSCAD = installedOpenSCADExecutable()
        lookedForOpenSCAD = true
    }

    private var closeConfirmation: (title: String, message: String)? {
        accessoryCloseConfirmation(designStarted: run?.hasStarted == true, ideasHeld: !suggestions.ideas.isEmpty,
                                   suggesting: suggestions.isWorking)
    }

    private func requestClose() {
        if closeConfirmation != nil { confirmClose = true } else { close() }
    }

    /// One Activity entry per suggestion request: counts, cost and status only. Holds the store itself, because the
    /// request may end after the sheet has gone.
    private var logSuggestion: AccessorySuggestionRun.Log {
        let store = store
        return { detail, success in
            store.activities.insert(Activity(title: "Design an accessory", detail: detail, success: success), at: 0)
        }
    }

    private func close() {
        if suggestions.isWorking { suggestions.closeWhileWorking(log: logSuggestion) }
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
            ideasSection
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
        // Return keeps what's in the form.
        .confirmationDialog("Use this idea?", isPresented: Binding(get: { pendingIdea != nil }, set: { if !$0 { pendingIdea = nil } }),
                            titleVisibility: .visible, presenting: pendingIdea) { idea in
            Button("Replace") {
                pendingIdea = nil
                applyIdea(idea)
            }
            Button("Keep Current Details", role: .cancel) { pendingIdea = nil }
                .keyboardShortcut(.defaultAction)
        } message: { _ in
            Text("What to make becomes this idea’s description and its measurements are added. Measurements you typed are kept; empty rows are removed.")
        }
    }

    // MARK: Ideas

    private var currentSuggestionInputs: AccessorySuggestionInputs {
        AccessorySuggestionInputs(photoIDs: photos.map(\.id), hint: objectHint)
    }

    private var ideasStaleReason: String? {
        accessoryIdeasStaleReason(suggestedFor: suggestions.suggestedFor, current: currentSuggestionInputs)
    }

    private var suggestMode: AccessorySuggestMode {
        accessorySuggestMode(ideaCount: suggestions.ideas.count, stale: ideasStaleReason != nil, attempted: suggestions.attempted)
    }

    private var suggestBlockedReason: String? {
        accessorySuggestBlockedReason(photoCount: photos.count, preparingPhotos: preparingPhotos, claudeConfigured: anthropic.isConfigured,
                                      suggesting: suggestions.isWorking, designStarted: run != nil, hintLength: objectHint.count,
                                      ideaCount: suggestions.ideas.count, mode: suggestMode)
    }

    private var suggestHelp: String {
        switch suggestMode {
        case .first: return "Claude looks at your photos and suggests accessories to sell. One request, billed to your Anthropic account."
        case .again where !suggestions.ideas.isEmpty:
            return "Replaces these ideas with new ones for your current photos and your answer to What is it? One request, billed again."
        case .again: return "Sends a new request. It is billed again."
        case .more: return "Asks for ideas other than these and adds them to the list. One request, billed again."
        }
    }

    private var suggestionCostText: String {
        let sizes: [(width: Int, height: Int)] = photos.isEmpty ? [(1568, 1176)] : photos.map { ($0.image.pixelWidth, $0.image.pixelHeight) }
        let avoid = suggestMode == .more ? suggestions.ideas.map(\.title) : []
        let text = accessorySuggestionTurnText(photoCount: max(1, photos.count), hint: objectHint, avoidTitles: avoid)
        return accessorySuggestionCostForecastText(accessorySuggestionCostForecast(photoSizes: sizes, textCharacters: text.count))
    }

    private var ideasSection: some View {
        Section {
            TextField("What is it?", text: $objectHint, prompt: Text("Optional, such as “Sony WH-1000XM5 headphones”"))
                .accessibilityLabel("What is it?")
                .help("Your hint outranks what Claude sees in the photos.")
            suggestControls
            if let message = suggestions.message {
                Label(message.text, systemImage: message.isProblem ? "exclamationmark.triangle" : "checkmark.circle")
                    .foregroundStyle(message.isProblem ? Color.orange : Color.secondary).font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !suggestions.ideas.isEmpty {
                if let ideasStaleReason {
                    Label(ideasStaleReason + " You can still use them.", systemImage: "clock.arrow.circlepath")
                        .foregroundStyle(.orange).font(.callout).fixedSize(horizontal: false, vertical: true)
                }
                if let identification = suggestions.identification {
                    identificationView(identification)
                }
                ForEach(suggestions.ideas) { idea in
                    ideaCard(idea)
                }
            }
            if let ideaNotice {
                Label(ideaNotice, systemImage: "info.circle").foregroundStyle(.secondary).font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } header: {
            Text("Ideas")
        } footer: {
            Text("Optional. Claude looks at your photos, says what the object is and suggests accessories you could sell for it. Using an idea fills in what to make and the measurements to take; nothing is designed until you press Start Design.")
                .settingsFooterLayout()
        }
    }

    @ViewBuilder
    private var suggestControls: some View {
        if let progress = suggestions.progress {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    ProgressView().controlSize(.small)
                    Text(progress).foregroundStyle(.secondary).lineLimit(1)
                    Spacer()
                    Button("Stop") { suggestions.stop() }
                        .help("Stops the request. Anthropic may bill the part Claude has already written.")
                }
                Text("Stopping may still be billed for the part Claude has already written.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        } else {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    // Never the default button and no shortcut: every press is a billed request.
                    Button(suggestMode.buttonTitle) { suggestTapped() }
                        .buttonStyle(.bordered)
                        .disabled(suggestBlockedReason != nil)
                        .help(suggestHelp)
                    if let reason = suggestBlockedReason {
                        Text(reason).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                }
                Text(suggestionCostText).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        if let spent = accessorySuggestionSpentText(cost: suggestions.cost, mayBeHigher: suggestions.costMayBeHigher, requests: suggestions.requests) {
            Text(spent).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func identificationView(_ identification: AccessoryObjectIdentification) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(accessoryIdentificationLine(identification)).font(.callout.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
            ForEach(Array(accessoryIdentificationDetailLines(identification, notes: suggestions.notes).enumerated()), id: \.offset) { _, line in
                Text(line).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if !identification.alternatives.isEmpty {
                HStack(spacing: 6) {
                    Text("Or it could be:").font(.caption).foregroundStyle(.secondary)
                    ForEach(Array(identification.alternatives.enumerated()), id: \.offset) { _, alternative in
                        Button(alternative) { objectHint = alternative }
                            .controlSize(.small)
                            .lineLimit(1)
                            .help("Puts this in What is it? Nothing is sent.")
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func ideaCard(_ idea: AccessoryIdea) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(idea.title).font(.headline).fixedSize(horizontal: false, vertical: true)
                Spacer()
                if accessoryIdeaIsInUse(idea, brief: brief) {
                    Label("In use", systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.callout)
                } else {
                    Button("Use This Idea") { useIdea(idea) }
                        .help("Fills in what to make and the measurements to take. Nothing is sent.")
                }
            }
            Text(idea.description).fixedSize(horizontal: false, vertical: true)
            if !idea.whoWantsIt.isEmpty {
                Text("Who wants it: \(idea.whoWantsIt)").font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Text(accessoryIdeaFitText(idea.fit)).font(.caption)
                .foregroundStyle(idea.fit == .tight ? Color.orange : Color.secondary)
            if let hardware = accessoryIdeaHardwareText(idea) {
                Text(hardware).font(.caption).fixedSize(horizontal: false, vertical: true)
            }
            if let measure = accessoryIdeaMeasureText(idea) {
                Text(measure).font(.caption).fixedSize(horizontal: false, vertical: true)
            }
            if !idea.caution.isEmpty {
                Label(idea.caution, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
    }

    private func suggestTapped() {
        guard suggestBlockedReason == nil else { return }
        // The same one-time consent as Start Design; Don't Send is the default.
        runWithImageSharingConsent(.anthropic, request: $consentRequest) { beginSuggesting() }
    }

    private func beginSuggesting() {
        guard suggestBlockedReason == nil else { return }
        suggestions.suggest(photos: photos.map(\.image), hint: objectHint, inputs: currentSuggestionInputs,
                            append: suggestMode == .more, log: logSuggestion)
    }

    private func useIdea(_ idea: AccessoryIdea) {
        if accessoryIdeaNeedsConfirmation(brief, idea: idea) { pendingIdea = idea } else { applyIdea(idea) }
    }

    private func applyIdea(_ idea: AccessoryIdea) {
        let leftOut = accessoryIdeaMeasurementsLeftOut(brief, idea: idea)
        brief = accessoryBriefApplyingIdea(brief, idea: idea)
        startProblem = nil
        ideaNotice = leftOut == 0 ? nil
            : "\(leftOut == 1 ? "1 of the idea’s measurements wasn’t" : "\(leftOut) of the idea’s measurements weren’t") added: use at most \(accessoryMaximumMeasurements)."
    }

    /// The idea the design starts from, while "What to make" is still its description.
    private var designIdeaContext: AccessoryDesignIdeaContext? {
        guard let idea = suggestions.ideas.first(where: { accessoryIdeaIsInUse($0, brief: brief) }) else { return nil }
        return AccessoryDesignIdeaContext(objectHint: objectHint, identification: ideasStaleReason == nil ? suggestions.identification : nil,
                                          idea: idea)
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
        let caption = accessoryMeasurementGuidanceCaption(row.wrappedValue)
        return VStack(alignment: .leading, spacing: 2) {
            measurementFields(row, caption: caption)
            if let caption {
                Text("How to measure: \(caption)").font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func measurementFields(_ row: Binding<AccessoryMeasurement>, caption: String?) -> some View {
        HStack(spacing: 8) {
            TextField("Measurement", text: row.label, prompt: Text("Phone thickness"))
                .labelsHidden()
                .accessibilityLabel("Measurement name")
                .help(caption ?? "")
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
                    Label("Add your Anthropic API key in Settings › Design Tools › Claude (Anthropic).", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                    Spacer()
                    Button("Open Settings") { store.requestSettings(.designTools) }
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
        if suggestions.isWorking { return "Wait for Claude’s ideas, or stop them." }
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
        newRun.start(firstTurn: accessoryFirstTurn(brief, photos: photos.map(\.image), ideaContext: designIdeaContext))
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
            fitSection(render.facts.fitSizes)
            Text("Advisory only: these checks and Claude’s notes can’t tell how strong a part will be. Test-print it before selling.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The seller's measurements beside the sizes the design reported, so a slot or hole can be checked by eye.
    private func fitSection(_ fitSizes: [AccessoryFitSize]) -> some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Your measurements").font(.subheadline.weight(.semibold))
                ForEach(Array(accessoryTypedMeasurementLines(brief.measurements).enumerated()), id: \.offset) { _, line in
                    Text(line).font(.callout).fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .leading, spacing: 4) {
                Text("Sizes that must fit, in this version").font(.subheadline.weight(.semibold))
                ForEach(Array(accessoryFitSizeLines(fitSizes).enumerated()), id: \.offset) { _, line in
                    Text(line).font(.callout).foregroundStyle(fitSizes.isEmpty ? .secondary : .primary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.top, 4)
        .accessibilityElement(children: .contain)
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
