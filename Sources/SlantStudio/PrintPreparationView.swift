import SwiftUI

// The automatic print-ready copy's surfaces (PrintPreparation.swift): the library row note, the inspector panel on the
// original and on the copy, and Settings › Design Tools › Prepare new models for printing.

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

/// The inspector's account of the automatic preparation: progress and Stop while it runs; on the original, what
/// happened (with Show Copy); on the copy, what was applied and skipped, Studio's numbers, the price note and the
/// optional fit-affecting Auto-improve.
struct PrintPreparationPanel: View {
    @EnvironmentObject var store: StudioStore
    @ObservedObject var queue: PrintPreparationQueue
    let model: LocalModel
    @StateObject private var followUp = AutoImproveRun()
    @State private var confirmFollowUp = false

    /// Shown only when there is something to say.
    static func isRelevant(_ model: LocalModel, queue: PrintPreparationQueue) -> Bool {
        queue.isPreparing(model.id) || model.printPreparation != nil || model.printPreparationStatus != nil
    }

    var body: some View {
        Group {
            if Self.isRelevant(model, queue: queue) {
                Card {
                    VStack(alignment: .leading, spacing: 10) {
                        if queue.isPreparing(model.id) {
                            progressView
                        } else if let record = model.printPreparation {
                            copySummary(record)
                        } else if let status = model.printPreparationStatus {
                            originalSummary(status)
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

    @ViewBuilder private func originalSummary(_ status: PrintPreparationStatus) -> some View {
        switch status.outcome {
        case .madeCopy:
            let copy = status.copyID.flatMap { id in store.localModels.first { $0.id == id } }
            if let copy {
                SectionHeading(title: "Print-ready copy", caption: "Studio made a print-ready copy: \(copy.name). This model is unchanged.")
                Button("Show Copy") { store.select(copy) }.disabled(store.busy)
            } else {
                SectionHeading(title: "Print-ready copy", caption: "Studio made a print-ready copy, which has since been removed from your library. This model is unchanged.")
            }
        case .nothingToChange:
            SectionHeading(title: "Print-ready copy", caption: printPreparationNothingToChange)
            lines(status.lines, title: "What Studio checked")
        case .noCopy:
            SectionHeading(title: "Print-ready copy", caption: "No print-ready copy was made.")
            ForEach(status.lines, id: \.self) { Text($0).font(.callout).foregroundStyle(.secondary) }
        case .stopped:
            SectionHeading(title: "Print-ready copy", caption: "Preparing for printing was stopped, so no copy was made. The tools below still work.")
        }
    }

    @ViewBuilder private func copySummary(_ record: PrintPreparationRecord) -> some View {
        SectionHeading(title: "Print-ready copy", caption: printPreparationCaption(record))
        ForEach(printPreparationAppliedLines(record), id: \.self) { line in
            Label(line, systemImage: "checkmark.circle").font(.callout)
        }
        lines(printPreparationSkippedLines(record), title: "Skipped or not needed")
        lines(record.notes, title: "For your review")
        Text(printPreparationPriceNote).font(.caption).foregroundStyle(.secondary)
        HStack {
            if let original = store.localModels.first(where: { $0.id == record.sourceID }) {
                Button("Show Original") { store.select(original) }.disabled(store.busy)
            }
            if model.autoImprovement == nil, model.supportsPreview {
                Button(followUp.working ? "Adding…" : "Nothing on this part has to fit? Add Fillets and Thicken Walls…") {
                    confirmFollowUp = true
                }
                .disabled(followUp.working || store.busy)
                if followUp.working {
                    ProgressView().controlSize(.small)
                    Text(followUp.status).font(.caption).foregroundStyle(.secondary)
                    Button("Stop") { followUp.stop() }
                }
            }
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
                    // Turned off: nothing more is prepared this session, including models already waiting.
                    if !on { store.printPreparationQueue.stopAll() }
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
