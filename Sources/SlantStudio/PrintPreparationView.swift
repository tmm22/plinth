import SwiftUI

// The print-ready copy's surfaces (PrintPreparation.swift): the library row note, the inspector panel on the original
// and on the copy, the action bar's hint, the one-time notice and Settings › Design Tools › Prepare new models for
// printing.

/// "Preparing for printing…" under a library row while its model is queued or being prepared.
struct PrintPreparationRowNote: View {
    @ObservedObject var queue: PrintPreparationQueue
    let modelID: UUID

    var body: some View {
        if queue.isPreparing(modelID) {
            Text("Preparing for printing…").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        }
    }
}

/// The one-time notice after the first automatic copy. Only its dismissal is stored.
struct PrintPreparationFirstCopyNotice: View {
    @ObservedObject var queue: PrintPreparationQueue

    var body: some View {
        if queue.showsFirstCopyNotice {
            HStack(spacing: 10) {
                Label(printPreparationNoticeText, systemImage: "info.circle")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button("Dismiss") { queue.dismissFirstCopyNotice() }
            }
            .padding(10)
            .background(Color.studioCard, in: RoundedRectangle(cornerRadius: StudioMetrics.cardRadius))
            .overlay(RoundedRectangle(cornerRadius: StudioMetrics.cardRadius).stroke(Color.studioHairline))
        }
    }
}

/// The action bar's one-line hint under Upload Model when the selected original has a print-ready copy. Show Copy only
/// selects it; nothing is uploaded.
struct PrintReadyCopyHint: View {
    @EnvironmentObject var store: StudioStore
    let model: LocalModel

    var body: some View {
        if model.printPreparation == nil, let copy = printReadyCopy(of: model, in: store.localModels) {
            HStack(spacing: 6) {
                Text("A print-ready copy exists").font(.caption).foregroundStyle(.secondary)
                Button("Show Copy") { store.select(copy) }
                    .buttonStyle(.link).font(.caption)
                    .disabled(store.busy)
            }
        }
    }
}

/// The inspector's account of preparation for an STL model: progress and Stop while it runs; on the original, what
/// happened (with Show Copy) and Make Print-Ready Copy; on the copy, what was applied and skipped, Studio's numbers,
/// the price and cautions, and the optional fit-affecting Auto-improve.
struct PrintPreparationPanel: View {
    @EnvironmentObject var store: StudioStore
    @ObservedObject var queue: PrintPreparationQueue
    let model: LocalModel
    @StateObject private var followUp = AutoImproveRun()
    @State private var confirmFollowUp = false

    var body: some View {
        Group {
            if model.supportsPreview {
                Card {
                    VStack(alignment: .leading, spacing: 10) {
                        if queue.isPreparing(model.id) {
                            progressView
                        } else if let record = model.printPreparation {
                            copySummary(record)
                        } else {
                            originalSummary(model.printPreparationStatus)
                        }
                    }
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .alert("Add Fillets and Thicken Walls?", isPresented: $confirmFollowUp) {
            Button("Add Fillets and Thicken Walls") {
                followUp.improveAndSaveCopy(of: model, intent: designEditIntent(model) ?? PartIntent(), profile: .fitAffecting, store: store)
            }
            Button("Cancel", role: .cancel) {}
                .keyboardShortcut(.defaultAction)
        } message: {
            Text("Fillets fill inside corners and thickened walls take space from cavities, so holes, slots and faces that meet another part can come out tighter. Do this only if nothing on this part has to fit. Plinth saves a further copy and keeps this one.")
        }
        .onDisappear { followUp.stop() }
    }

    private var progressView: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionHeading(title: "Preparing for printing…", caption: "Plinth is making a separate print-ready copy. This model stays as it is.")
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                if queue.current?.modelID == model.id, !queue.status.isEmpty {
                    Text(queue.status).font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("Waiting for the model before it…").font(.caption).foregroundStyle(.secondary)
                }
                Button("Stop") { queue.stop(modelID: model.id) }
            }
        }
    }

    private var makeCopyButton: some View {
        Button("Make Print-Ready Copy") { store.makePrintReadyCopy(modelID: model.id) }
            .disabled(printPreparationManualBlockedReason(model) != nil)
    }

    /// Show Copy whenever an earlier print-ready copy is still in the library, then Make Print-Ready Copy.
    private var originalActions: some View {
        HStack {
            if let copy = printReadyCopy(of: model, in: store.localModels) {
                Button("Show Copy") { store.select(copy) }.disabled(store.busy)
            }
            makeCopyButton
        }
    }

    @ViewBuilder private func originalSummary(_ status: PrintPreparationStatus?) -> some View {
        switch status?.outcome {
        case .madeCopy?:
            if let copy = printReadyCopy(of: model, in: store.localModels) {
                SectionHeading(title: "Print-ready copy saved", caption: "\(copy.name). This model is unchanged.")
            } else {
                SectionHeading(title: "Print-ready copy", caption: "Plinth made a print-ready copy, which has since been removed from your library. This model is unchanged.")
            }
            originalActions
        case .nothingToChange?:
            SectionHeading(title: "Print-ready copy", caption: printPreparationNothingToChange)
            lines(status?.lines ?? [], title: "What Plinth checked")
            originalActions
        case .noCopy?:
            SectionHeading(title: "Print-ready copy", caption: "No new print-ready copy was made.")
            ForEach(status?.lines ?? [], id: \.self) { Text($0).font(.callout).foregroundStyle(.secondary) }
            originalActions
        case .stopped?:
            SectionHeading(title: "Print-ready copy", caption: "Preparation stopped · Make Print-Ready Copy to try again.")
            ForEach(status?.lines ?? [], id: \.self) { Text($0).font(.callout).foregroundStyle(.secondary) }
            originalActions
        case nil:
            if let reason = printPreparationManualBlockedReason(model), model.fromPrintReadyCopy == true {
                SectionHeading(title: "Print-ready copy", caption: reason)
            } else {
                HStack {
                    SectionHeading(title: "Print-ready copy", caption: printPreparationOfferCaption(PrintPreparationSettings(defaults: .standard)))
                    Spacer(minLength: 8)
                    makeCopyButton
                }
            }
        }
    }

    @ViewBuilder private func copySummary(_ record: PrintPreparationRecord) -> some View {
        SectionHeading(title: "Print-ready copy", caption: printPreparationCaption(record))
        // One short sentence per step; the figures are under Details.
        ForEach(printPreparationAppliedLines(record), id: \.self) { line in
            Label(line, systemImage: "checkmark.circle").font(.callout)
        }
        if let filled = record.hiddenPockets.flatMap(printPreparationPocketsFilledLine) {
            Label(filled, systemImage: "checkmark.circle").font(.callout)
        }
        if let overhangs = record.overhangs {
            Label(printPreparationOverhangLine(overhangs), systemImage: "ruler").font(.callout)
        }
        ForEach(printPreparationCautions(record), id: \.self) { line in
            Label(line, systemImage: "exclamationmark.triangle").font(.callout)
        }
        advisories(printPreparationAdvisoryItems(record))
        if let pockets = record.hiddenPockets, let line = hiddenPocketsLine(pockets) {
            // Never filled automatically: the seller's own Fill Hidden Pockets saves a further copy.
            HiddenPocketsRow(run: store.hiddenPocketsFill, line: line, model: model)
        } else if record.hiddenPockets?.incomplete == true {
            Label(hiddenPocketsIncompleteLine, systemImage: "info.circle").font(.callout).foregroundStyle(.secondary)
        }
        lines(printPreparationDetailLines(record), title: "Details")
        lines(printPreparationSkippedLines(record), title: "Skipped or not needed")
        lines(record.notes, title: "For your review")
        Text(printPreparationPriceLine(record)).font(.caption).foregroundStyle(.secondary)
        if let original = store.localModels.first(where: { $0.id == record.sourceID }) {
            Button("Show Original") { store.select(original) }.disabled(store.busy)
        }
        // Both fit-changing follow-ups in one row, under one caption.
        FitChangingFollowUps(queue: queue, model: model, record: record, fillets: model.autoImprovement == nil) {
            Button(followUp.working ? "Adding…" : "Add Fillets and Thicken Walls…") { confirmFollowUp = true }
                .disabled(followUp.working || store.busy)
            if followUp.working {
                ProgressView().controlSize(.small)
                Text(followUp.status).font(.caption).foregroundStyle(.secondary)
                Button("Stop") { followUp.stop() }
            }
        }
        if let result = followUp.unchanged {
            Text("No fillets or wall matching suit this part, so nothing was saved.").font(.callout)
            lines(result.skipped + result.manual, title: "Details")
        }
    }

    /// Print advisories on the copy: up to `printPreparationAdvisoriesShownInline` inline, more in a collapsed list.
    /// Contact and tipping advisories are always inline.
    @ViewBuilder private func advisories(_ items: [PrintPreparationAdvisoryLine]) -> some View {
        let split = printPreparationAdvisorySplit(items)
        ForEach(Array(split.inline.enumerated()), id: \.offset) { item in
            Label(item.element, systemImage: "info.circle").font(.callout)
        }
        lines(split.collapsed, title: "Print checks")
    }

    @ViewBuilder private func lines(_ lines: [String], title: String) -> some View {
        if !lines.isEmpty {
            DisclosureGroup("\(title) (\(lines.count))") {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { Text($0.element) }
                }
                .font(.callout).foregroundStyle(.secondary).padding(.top, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
            }.studioDisclosureStyle()
        }
    }
}

// MARK: - Fit-changing follow-ups

/// In memory, per copy and original file (library files are never changed in place). Cleared when the app quits.
@MainActor enum TeardropOfferCache {
    static var offers: [String: PrintPreparationTeardropOffer] = [:]
}

/// A print-ready copy's fit-changing follow-ups in one row under one caption: Add Fillets and Thicken Walls… (`fillets`,
/// the panel's own button) and Add Teardrop Holes…. Teardrops are offered only when the original, placed as this copy
/// is, has horizontal round holes that can take a teardrop roof (found in the background, stopped when the panel goes,
/// cached). Pressing it asks which holes, none ticked; only the confirmation's own button queues the new copy. Never
/// automatic, local only, and no keyboard shortcut starts either.
struct FitChangingFollowUps<Fillets: View>: View {
    @EnvironmentObject var store: StudioStore
    @ObservedObject var queue: PrintPreparationQueue
    let model: LocalModel
    let record: PrintPreparationRecord
    let fillets: Bool
    @ViewBuilder let filletsButton: () -> Fillets
    @State private var offer: PrintPreparationTeardropOffer?
    @State private var offerKey = ""
    @State private var confirming = false

    private var original: LocalModel? { store.localModels.first { $0.id == record.sourceID } }
    private var teardropsApply: Bool { printPreparationTeardropOfferApplies(model, library: store.localModels) }
    private var cacheKey: String {
        guard teardropsApply, let original else { return "" }
        return "\(model.id.uuidString)|\(model.filePath)|\(original.filePath)"
    }

    var body: some View {
        let key = cacheKey
        let running = teardropsApply ? queue.teardropJob(for: record.sourceID) : nil
        let holes = (!key.isEmpty && offerKey == key) ? (offer?.eligible.count ?? 0) : 0
        VStack(alignment: .leading, spacing: 6) {
            if let latest = original.flatMap({ printReadyCopy(of: $0, in: store.localModels) }), latest.id != model.id,
               latest.printPreparation?.hasTeardropHoles == true {
                HStack(spacing: 6) {
                    Text("Saved with teardrop holes: \(latest.name)").font(.callout).foregroundStyle(.secondary)
                    Button("Show Copy") { store.select(latest) }.buttonStyle(.link).disabled(store.busy)
                }
            }
            if let caption = printPreparationFitChangingCaption(fillets: fillets, teardropHoles: running == nil ? holes : 0) {
                Text(caption).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                if fillets { filletsButton() }
                if let running {
                    ProgressView().controlSize(.small)
                    Text(running.running && !queue.status.isEmpty ? queue.status : "Waiting to add teardrop holes…")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Stop") { queue.stop(modelID: record.sourceID) }
                } else if holes > 0 {
                    Button("Add Teardrop Holes…") { confirming = true }
                        .disabled(store.busy || queue.isPreparing(record.sourceID))
                }
            }
            if teardropsApply, let outcome = queue.teardropOutcome, outcome.sourceID == record.sourceID, running == nil {
                Text(outcome.message).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .task(id: key) {
            guard !key.isEmpty, let url = original?.url else { return }
            if let cached = TeardropOfferCache.offers[key] { offer = cached; offerKey = key; return }
            let record = record
            let worker = Task.detached(priority: .utility) { () -> PrintPreparationTeardropOffer? in
                guard let source = try? STLMesh.read(from: url) else { return nil }
                return try? printPreparationTeardropOffer(original: source, record: record, isCancelled: { Task.isCancelled })
            }
            let found = await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
            guard !Task.isCancelled, let found else { return }
            TeardropOfferCache.offers[key] = found
            offer = found
            offerKey = key
        }
        .sheet(isPresented: $confirming) {
            if let offer {
                TeardropHolesConfirmation(offer: offer, text: printPreparationTeardropConfirmText(
                    PrintPreparationSettings(defaults: .standard), decorative: designEditIntent(original ?? model)?.purpose == .decorative)) { keys in
                    store.addTeardropHoles(from: model, keys: keys)
                }
            }
        }
    }
}

/// Which holes get a teardrop roof: none ticked until the seller chooses. Cancel is the default button; Add Teardrop
/// Holes has no shortcut. Each hole is named in words; its figures are in the help tag.
struct TeardropHolesConfirmation: View {
    @Environment(\.dismiss) private var dismiss
    let offer: PrintPreparationTeardropOffer
    let text: String
    let confirm: ([TeardropHoleKey]) -> Void
    @State private var chosen: Set<TeardropHoleKey> = []
    @State private var leftAloneExpanded = false

    var body: some View {
        // Over both lists, so no two holes read the same.
        let labels = teardropCandidateLabels(offer.holes, low: offer.minimum, high: offer.maximum)
        VStack(alignment: .leading, spacing: 14) {
            Text("Add teardrop holes").font(.title3.weight(.semibold))
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 6) {
                ForEach(offer.eligible) { hole in
                    Toggle((labels[hole.key] ?? teardropCandidateLabel(hole, low: offer.minimum, high: offer.maximum)), isOn: Binding(
                        get: { chosen.contains(hole.key) },
                        set: { on in if on { chosen.insert(hole.key) } else { chosen.remove(hole.key) } }))
                        .fixedSize(horizontal: false, vertical: true)
                        .help(teardropCandidateDetail(hole, minimum: offer.minimum))
                }
            }
            if !offer.leftAlone.isEmpty {
                DisclosureGroup("Left as they are (\(offer.leftAlone.count))", isExpanded: $leftAloneExpanded) {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(offer.leftAlone) { hole in
                            Text((labels[hole.key] ?? teardropCandidateLabel(hole, low: offer.minimum, high: offer.maximum)) + ": " + (hole.skipped?.message ?? ""))
                                .help(teardropCandidateDetail(hole, minimum: offer.minimum))
                        }
                    }
                    .font(.callout).foregroundStyle(.secondary).padding(.top, 4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .studioDisclosureStyle()
            }
            HStack {
                Text(chosen.isEmpty ? teardropTickCaption : "\(chosen.count) ticked")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.defaultAction)
                Button("Add Teardrop Holes") {
                    let keys = offer.eligible.map(\.key).filter(chosen.contains)
                    dismiss()
                    confirm(keys)
                }
                .disabled(chosen.isEmpty)
            }
        }
        .padding(20)
        .frame(minWidth: 460, idealWidth: 540, maxWidth: 640)
        .onExitCommand { dismiss() }
    }
}

/// Settings › Design Tools › Prepare new models for printing.
struct PrintPreparationSettingsSection: View {
    @EnvironmentObject var store: StudioStore
    @AppStorage(printPreparationEnabledDefaultsKey) private var enabled = true
    @AppStorage(printPreparationInternalWallsDefaultsKey) private var internalWalls = true
    @AppStorage(printPreparationBottomChamferDefaultsKey) private var bottomChamfer = true

    var body: some View {
        Section {
            Toggle("Make a print-ready copy of each new STL", isOn: $enabled)
                .onChange(of: enabled) { _, on in
                    // Turned off: nothing more is prepared automatically this session, including models already waiting.
                    if !on { store.printPreparationQueue.stopAll(automaticOnly: true) }
                }
            // Both also apply to Make Print-Ready Copy, so they stay available when automatic copies are off.
            Toggle(isOn: $bottomChamfer) {
                Text("Add a 0.4 mm bottom-edge chamfer")
                Text(printPreparationBottomChamferCaption)
            }
            Toggle(isOn: $internalWalls) {
                Text("Add internal walls")
                Text(printPreparationInternalWallsCaption)
            }
        } header: {
            Text("Prepare new models for printing")
        } footer: {
            Text(printPreparationSettingsFooter).settingsFooterLayout()
        }
    }
}
