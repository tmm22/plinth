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
            Text("Fillets fill inside corners and thickened walls take space from cavities, so holes, slots and faces that meet another part can come out tighter. Do this only if nothing on this part has to fit. Studio saves a further copy and keeps this one.")
        }
        .onDisappear { followUp.stop() }
    }

    private var progressView: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionHeading(title: "Preparing for printing…", caption: "Studio is making a separate print-ready copy. This model stays as it is.")
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
                SectionHeading(title: "Print-ready copy", caption: "Studio made a print-ready copy, which has since been removed from your library. This model is unchanged.")
            }
            originalActions
        case .nothingToChange?:
            SectionHeading(title: "Print-ready copy", caption: printPreparationNothingToChange)
            lines(status?.lines ?? [], title: "What Studio checked")
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
            HStack {
                SectionHeading(title: "Print-ready copy", caption: "Repair if needed, placement, bridging, chamfers and internal walls, in a separate copy.")
                Spacer(minLength: 8)
                makeCopyButton
            }
        }
    }

    @ViewBuilder private func copySummary(_ record: PrintPreparationRecord) -> some View {
        SectionHeading(title: "Print-ready copy", caption: printPreparationCaption(record))
        ForEach(printPreparationAppliedLines(record), id: \.self) { line in
            Label(line, systemImage: "checkmark.circle").font(.callout)
        }
        ForEach(printPreparationCautions(record), id: \.self) { line in
            Label(line, systemImage: "exclamationmark.triangle").font(.callout)
        }
        lines(printPreparationSkippedLines(record), title: "Skipped or not needed")
        lines(record.notes, title: "For your review")
        Text(printPreparationPriceLine(record)).font(.caption).foregroundStyle(.secondary)
        HStack {
            if let original = store.localModels.first(where: { $0.id == record.sourceID }) {
                Button("Show Original") { store.select(original) }.disabled(store.busy)
            }
            if model.autoImprovement == nil {
                Button(followUp.working ? "Adding…" : "Add Fillets and Thicken Walls…") { confirmFollowUp = true }
                    .disabled(followUp.working || store.busy)
                if followUp.working {
                    ProgressView().controlSize(.small)
                    Text(followUp.status).font(.caption).foregroundStyle(.secondary)
                    Button("Stop") { followUp.stop() }
                }
            }
        }
        if model.autoImprovement == nil {
            Text("Only if nothing on this part has to fit.").font(.caption).foregroundStyle(.secondary)
        }
        if let result = followUp.unchanged {
            Text("No fillets or wall matching suit this part, so nothing was saved.").font(.callout)
            lines(result.skipped + result.manual, title: "Details")
        }
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

/// Settings › Design Tools › Prepare new models for printing.
struct PrintPreparationSettingsSection: View {
    @EnvironmentObject var store: StudioStore
    @AppStorage(printPreparationEnabledDefaultsKey) private var enabled = true
    @AppStorage(printPreparationInternalWallsDefaultsKey) private var internalWalls = true

    var body: some View {
        Section {
            Toggle("Make a print-ready copy of each new STL", isOn: $enabled)
                .onChange(of: enabled) { _, on in
                    // Turned off: nothing more is prepared automatically this session, including models already waiting.
                    if !on { store.printPreparationQueue.stopAll(automaticOnly: true) }
                }
            Toggle(isOn: $internalWalls) {
                Text("Add internal walls")
                Text(printPreparationInternalWallsCaption)
            }
            .disabled(!enabled)
        } header: {
            Text("Prepare new models for printing")
        } footer: {
            Text(printPreparationSettingsFooter).settingsFooterLayout()
        }
    }
}
