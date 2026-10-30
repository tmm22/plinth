import SwiftUI

// Get 3DAPI Quote… in Models › Print configuration, and its sheet. The flow and every rule live in DapiQuote.swift;
// this file only shows them. Nothing here has a keyboard shortcut or is a default button: quoting sends the model's
// file to 3DAPI, so it takes a click.

/// The model the sheet was opened for, captured once so a later selection change can't swap the file being quoted.
struct DapiQuoteModel: Equatable {
    let id: UUID
    let name: String
    let url: URL
    let format: ModelFileFormat?
}

/// Shown only with a saved 3DAPI key and a local library model whose file exists.
struct DapiQuoteButton: View {
    @EnvironmentObject var store: StudioStore
    @ObservedObject private var connection = DapiConnection.shared
    @State private var presented: DapiQuoteModel?

    var body: some View {
        if connection.isConfigured, let local = store.selectedLocal,
           FileManager.default.fileExists(atPath: local.filePath) {
            Button("Get 3DAPI Quote…") {
                presented = DapiQuoteModel(id: local.id, name: local.name, url: local.url, format: ModelFileFormat(url: local.url))
            }
            .buttonStyle(.bordered)
            .help("Price this model on 3DAPI and compare it with Slant")
            .sheet(item: $presented) { model in
                DapiQuoteSheet(model: model).environmentObject(store)
            }
        }
    }
}

extension DapiQuoteModel: Identifiable {}

struct DapiQuoteSheet: View {
    @EnvironmentObject var store: StudioStore
    @ObservedObject private var connection = DapiConnection.shared
    @Environment(\.dismiss) private var dismiss
    let model: DapiQuoteModel
    @StateObject private var runner = DapiQuoteRunner(environment: .live())
    @State private var countryCode = ""
    @State private var quantityText = "1"
    @State private var fileSize: Int64?
    @State private var didSetDefaults = false

    private var quantity: Int? { printQuantity(quantityText) }
    private var destination: DapiShippingKey? {
        guard !countryCode.isEmpty, let quantity else { return nil }
        return DapiShippingKey(countryCode: countryCode, quantity: quantity)
    }
    private var modelInLibrary: Bool {
        store.localModels.contains { $0.id == model.id && $0.url == model.url }
    }
    private var getQuoteBlockedReason: String? {
        if !modelInLibrary { return "This model is no longer in the library." }
        if !connection.isConfigured { return "Add a 3DAPI key in Settings to get a quote." }
        if countryCode.isEmpty { return "Choose where it would be delivered." }
        if quantity == nil { return "Enter a quantity from 1 to 10,000." }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Get 3DAPI quote").font(.title2.weight(.bold))
                Text(modelLine).font(.callout).foregroundStyle(.secondary).lineLimit(1)
            }
            .padding(24)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    inputs
                    explanation
                    status
                    if runner.phase == .ready, let quote = runner.quote, let price = quote.price {
                        comparison(quote: quote, unitPrice: price)
                    }
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            footer.padding(20)
        }
        .frame(minWidth: 620, idealWidth: 700, maxWidth: 900, minHeight: 520, idealHeight: 660)
        .onAppear {
            connection.sheetOpened()
            let activityStore = store
            runner.log = { [weak activityStore] title, detail, success in
                guard let store = activityStore else { return }
                store.activities.insert(Activity(title: title, detail: detail, success: success), at: 0)
                store.activities = Array(store.activities.prefix(100))
            }
            if !didSetDefaults {
                didSetDefaults = true
                let region = defaultDeliveryCountry()
                countryCode = region.selection == orderCountryOtherTag ? region.customCode : region.selection
                quantityText = String(store.quantity)
                fileSize = dapiRegularFileSize(at: model.url)
            }
            runner.destination = destination
            Task { await connection.refreshOnboarding() }
        }
        .onDisappear {
            runner.close()
            connection.sheetClosed()
        }
        .onChange(of: countryCode) { _, _ in runner.destination = destination }
        .onChange(of: quantityText) { _, _ in runner.destination = destination }
    }

    private var modelLine: String {
        var parts = [model.name]
        if let format = model.format { parts.append(format.displayName) }
        if let fileSize { parts.append(ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file)) }
        return parts.joined(separator: " · ")
    }

    // MARK: Inputs

    private var inputs: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
            GridRow {
                Text("Deliver to").gridColumnAlignment(.trailing)
                countryPicker.frame(maxWidth: 280)
            }
            GridRow {
                Text("Quantity")
                HStack(spacing: 6) {
                    TextField("Quantity", text: $quantityText)
                        .labelsHidden()
                        .frame(width: 72)
                        .accessibilityLabel("Quantity")
                    Stepper("", value: Binding(get: { quantity ?? 1 }, set: { quantityText = String($0) }), in: 1...10_000)
                        .labelsHidden()
                        .accessibilityLabel("Quantity stepper")
                    if quantity == nil {
                        Label("Enter a whole number from 1 to 10,000.", systemImage: "exclamationmark.circle")
                            .font(.caption).foregroundStyle(.orange)
                    }
                }
            }
        }
    }

    /// The composer's choices: the shortlist, then every other country; "Choose a country" when the region is unknown.
    private var countryPicker: some View {
        let others = orderOtherCountryChoicesForCurrentLocale
        return Picker("Deliver to", selection: $countryCode) {
            Text("Choose a country").tag("")
            Divider()
            ForEach(orderCountryChoices, id: \.code) { Text($0.name).tag($0.code) }
            Divider()
            if !countryCode.isEmpty, !orderCountryChoices.contains(where: { $0.code == countryCode }),
               !others.contains(where: { $0.code == countryCode }) {
                Text("Country code \(countryCode)").tag(countryCode)
            }
            ForEach(others, id: \.code) { Text($0.name).tag($0.code) }
        }
        .labelsHidden()
    }

    private var explanation: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Get Quote sends this model’s file to 3DAPI under a neutral name (never the model’s name). 3DAPI keeps the file; its API has no way to delete it. Until your 3DAPI account is approved, each new quote uses one of this round’s quotes. A file quoted before is found and reused instead.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let allowance = dapiOnboardingAllowanceText(connection.onboarding) {
                Text(allowance + ".").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Status

    @ViewBuilder
    private var status: some View {
        switch runner.phase {
        case .idle:
            EmptyView()
        case .ready:
            if runner.quote?.price == nil {
                Label("3DAPI marked the quote ready but sent no price.", systemImage: "exclamationmark.triangle")
                    .font(.callout).foregroundStyle(.orange)
            }
        case .checkingFile:
            progress("Reading the model’s file…")
        case .lookingUp:
            progress("Looking for an earlier quote of this file…")
        case .uploading:
            progress(runner.stopRequested ? "Stopping once 3DAPI answers the upload…" : "Uploading the file to 3DAPI…")
        case .creating:
            progress(runner.stopRequested ? "Stopping once 3DAPI answers…" : "Asking 3DAPI for a quote…")
        case .processing:
            progress("3DAPI is slicing the model. This usually takes one to a few minutes.")
        case .paused(let message):
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Label(message, systemImage: "clock").font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Button("Check Again") { runner.checkAgain() }
                    .buttonStyle(.bordered)
                    .disabled(!connection.isConfigured)
                    .help("Read this quote from 3DAPI once more")
            }
        case .quoteFailed(let reason):
            Label(reason.map { "3DAPI couldn’t quote this file: \($0)" } ?? "3DAPI couldn’t quote this file and didn’t say why.",
                  systemImage: "exclamationmark.triangle")
                .font(.callout).foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        case .problem(let message):
            Label(message, systemImage: "exclamationmark.triangle")
                .font(.callout).foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func progress(_ text: String) -> some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(text).font(.callout).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: Comparison

    @ViewBuilder
    private func comparison(quote: DapiQuote, unitPrice: DapiMoney) -> some View {
        let sheetQuantity = quantity ?? runner.shippingFor?.quantity ?? 1
        let stale = dapiShippingIsStale(shippingFor: runner.shippingFor, destination: destination)
        let slantTotal = dapiSlantPrintTotal(
            estimate: store.estimate, estimateIsCurrent: store.estimateIsCurrent, sheetModelID: model.id,
            selectedLocalID: store.selectedLocalID, selectedRemoteID: store.selectedLocal?.remoteID, fileID: store.fileID,
            estimateQuantity: store.quantity, sheetQuantity: sheetQuantity)
        let rows = dapiComparisonRows(DapiComparisonInputs(
            unitPrice: unitPrice, quantity: sheetQuantity, countryCode: countryCode, shipping: runner.shipping,
            shippingIsStale: stale, slantPrintTotal: slantTotal,
            slantDelivery: dapiSlantDelivery(orders: store.orders, countryCode: countryCode)))
        VStack(alignment: .leading, spacing: 12) {
            Text("Comparison").font(.headline)
            shippingControls(stale: stale)
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 10) {
                GridRow {
                    Text("")
                    Text("3DAPI").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Text("Slant").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                }
                Divider().gridCellUnsizedAxes(.horizontal)
                ForEach(rows) { row in
                    GridRow(alignment: .top) {
                        Text(row.label).font(.callout)
                        cell(row.dapi).frame(maxWidth: .infinity, alignment: .leading)
                        cell(row.slant).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                ForEach(dapiComparisonNotes(countryCode: countryCode, shipping: stale ? nil : runner.shipping,
                                            suggestedMaterials: quote.suggestedMaterials,
                                            slantMaterialName: slantMaterialName), id: \.self) { note in
                    Text(note).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    @ViewBuilder
    private func shippingControls(stale: Bool) -> some View {
        if runner.shippingRequesting {
            progress("Pricing shipping…")
        } else if stale || runner.shippingProblem != nil || (runner.shipping == nil && destination != nil) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                if let problem = runner.shippingProblem {
                    Label(problem, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                } else if stale {
                    Label("Shipping and totals are for an earlier country or quantity.", systemImage: "exclamationmark.circle")
                        .font(.callout).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Button("Update Shipping") { if let destination { runner.requestShipping(destination) } }
                    .buttonStyle(.bordered)
                    .disabled(destination == nil || !connection.isConfigured)
                    .help("Ask 3DAPI for shipping to this country and quantity (nothing is ordered)")
            }
        } else if destination == nil {
            Text("Choose a country and quantity to price shipping.").font(.callout).foregroundStyle(.secondary)
        }
    }

    private func cell(_ cell: DapiComparisonCell) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(cell.value).font(.callout.weight(.semibold).monospacedDigit())
                .foregroundStyle(cell.isWarning ? Color.orange : Color.primary)
            if let note = cell.note {
                Text(note).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .textSelection(.enabled)
    }

    private var slantMaterialName: String? {
        guard store.selectedLocalID == model.id,
              let record = store.filaments.first(where: { $0.id == store.filamentID }) else { return nil }
        return materialDisplayName(displayName(for: record, fallback: ""))
    }

    // MARK: Footer

    /// Get Quote is offered until a quote is ready; while one is paused, Check Again reads it instead.
    private var showsGetQuote: Bool {
        guard !runner.isWorking else { return false }
        switch runner.phase {
        case .ready, .paused: return false
        default: return true
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Button("Close") { dismiss() }
                .keyboardShortcut(.cancelAction)
            if showsGetQuote, let reason = getQuoteBlockedReason {
                Text(reason).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if runner.isWorking {
                Button("Stop") { runner.stop() }
                    .disabled(runner.stopRequested)
                    .help(runner.writeInFlight ? "Stops once 3DAPI answers the request already sent" : "Stop asking 3DAPI; a quote already made carries on there")
            } else if showsGetQuote {
                // Never the default button and no shortcut: it sends the file.
                Button("Get Quote") { runner.getQuote(fileURL: model.url, format: model.format) }
                    .buttonStyle(.bordered)
                    .disabled(getQuoteBlockedReason != nil)
                    .help("Send this model’s file to 3DAPI for a price, or find the quote made for it before")
            }
        }
    }
}
