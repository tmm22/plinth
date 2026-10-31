import SwiftUI
import AppKit
import UniformTypeIdentifiers

// Views for the read-only 3DAPI order tools (DapiOrderInsights.swift): the order detail's extra sections (attention,
// Profit check, Report a Problem) and the Orders toolbar's Tools menu (Spending Report…, Export Orders…, Tracking for
// Your Shop…). None of them changes an order; Load the Whole Period is the only request, and it is read-only.

// MARK: - Detail sections

/// The order detail's extra section: the Profit check. (The attention reason is in the detail's header, and Report a
/// Problem… in its action row, `DapiReportProblemButton`.)
struct DapiOrderInsightsSection: View {
    let order: DapiOrder

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // `.id` so typed amounts never carry over to another order.
            DapiProfitCheckPanel(order: order).id(order.id)
        }
    }
}

/// Report a Problem… for the order detail's action row: opens the Copy-only message sheet; Plinth sends nothing.
/// Offer it only where `dapiOffersProblemReport` allows.
struct DapiReportProblemButton: View {
    let order: DapiOrder
    @State private var reportingProblem = false

    var body: some View {
        Button("Report a Problem…") { reportingProblem = true }
            .help("Put together a message about this order to send to 3DAPI. Nothing is sent by Plinth.")
            .sheet(isPresented: $reportingProblem) {
                DapiProblemReportSheet(order: order).dapiOrderSheetCounted()
            }
    }
}

/// Collapsed-by-default profit check for one 3DAPI order: Margin.swift's parsing, fee presets and maths with 3DAPI's
/// cost (`dapiOrderCost`). Only the preset and rates are saved (as Margin.swift already saves them); what the buyer
/// paid and the units sold are never saved.
struct DapiProfitCheckPanel: View {
    let order: DapiOrder
    @State private var expanded = false
    @State private var itemText = ""
    @State private var shippingText = ""
    @State private var preset = ProfitFeeSettings.loadPreset()
    @State private var rateTexts: [ProfitRateField: String] = [:]
    @State private var offsiteAds = false
    @State private var unitsText = "1"
    @State private var loadedRates = false
    @State private var ratesExpanded = false

    var body: some View {
        DisclosureGroup("Profit check", isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 10) {
                switch dapiOrderCost(order) {
                case .unavailable(let reason):
                    Text(reason).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                case .amount(let cost):
                    content(cost: cost)
                }
            }
            .labeledContentStyle(.receipt)
            .padding(.top, 6)
        }
        .studioDisclosureStyle()
        .onAppear { loadRatesIfNeeded() }
    }

    @ViewBuilder
    private func content(cost: Decimal) -> some View {
        Text(dapiProfitCheckEntryCaption)
            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        moneyField("Item total paid", text: $itemText)
        moneyField("Shipping charged", text: $shippingText)
        LabeledContent {
            Picker("Marketplace fees", selection: Binding(get: { preset }, set: { choosePreset($0) })) {
                ForEach(ProfitFeePreset.allCases) { Text($0.title).tag($0) }
            }
            .labelsHidden()
            .frame(maxWidth: 260)
        } label: {
            Text("Marketplace fees").fixedSize()
        }
        if preset.hasRates { rateFields }
        Divider()
        resultView(cost: cost)
    }

    private func moneyField(_ title: String, text: Binding<String>) -> some View {
        LabeledContent(title) {
            HStack(spacing: 4) {
                Text("$").foregroundStyle(.secondary)
                TextField(title, text: text, prompt: Text("0.00")).labelsHidden().accessibilityLabel(title)
                    .frame(width: 110).multilineTextAlignment(.trailing)
            }
        }
    }

    private var rateEditorNeedsAttention: Bool {
        profitRateEditorNeedsAttention(preset: preset, ratesValid: validRates != nil, currentRates: currentRates)
    }

    @ViewBuilder
    private var rateFields: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(validRates.map { profitFeeRatesSummary(preset: preset, rates: $0, offsiteAds: offsiteAds) }
                 ?? "\(preset.title): check the highlighted rates.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            DisclosureGroup("Edit rates", isExpanded: Binding(get: { ratesExpanded || rateEditorNeedsAttention },
                                                              set: { ratesExpanded = $0 })) {
                VStack(alignment: .leading, spacing: 6) {
                    if preset != .custom {
                        Text("Assumed rates. Check your own account and edit them if yours differ.")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    if preset != .shopifyBasicUS { rateField(.transactionPercent, "Transaction fee (% of item + shipping)") }
                    rateField(.processingPercent, "Payment processing (%)")
                    rateField(.processingFixed, "Payment processing ($ per order)")
                    if showsListingFee { rateField(.listingFeePerItem, "Listing fee ($ per unit sold)") }
                    if preset.offersOffsiteAds { rateField(.offsiteAdsPercent, "Offsite Ads fee (%, max $100)") }
                    if preset != .custom, currentRates != preset.defaultRates || rateTexts.values.contains(where: { $0.isEmpty }) {
                        Button("Restore \(preset.title) Rates") { restoreDefaults() }.controlSize(.small)
                    }
                }
                .padding(.top, 4)
            }
            .studioDisclosureStyle()
            if showsListingFee {
                LabeledContent("Units sold") {
                    VStack(alignment: .trailing, spacing: 2) {
                        TextField("Units sold", text: $unitsText).labelsHidden().accessibilityLabel("Units sold")
                            .frame(width: 80).multilineTextAlignment(.trailing)
                        if parseProfitUnitsSold(unitsText) == nil {
                            Text("Enter a whole number from 1").font(.caption2).foregroundStyle(.orange)
                        }
                    }
                }
                .help("How many units the buyer bought on the marketplace")
            }
            if preset.offersOffsiteAds {
                Toggle("This sale came from Offsite Ads", isOn: $offsiteAds)
            }
        }
    }

    private func rateField(_ field: ProfitRateField, _ title: String) -> some View {
        let binding = Binding(get: { rateTexts[field] ?? "" }, set: {
            if rateEditorNeedsAttention { ratesExpanded = true }
            rateTexts[field] = $0
            persist()
            if rateEditorNeedsAttention { ratesExpanded = true }
        })
        return LabeledContent(title) {
            VStack(alignment: .trailing, spacing: 2) {
                TextField(title, text: binding).labelsHidden().accessibilityLabel(title)
                    .frame(width: 80).multilineTextAlignment(.trailing)
                if rateValue(field) == nil {
                    Text(field.isPercent ? "Enter 0–100" : "Enter an amount").font(.caption2).foregroundStyle(.orange)
                }
            }
        }
    }

    @ViewBuilder
    private func resultView(cost: Decimal) -> some View {
        if itemText.trimmingCharacters(in: .whitespaces).isEmpty {
            Text("Enter the item total to see the estimated profit.").font(.callout).foregroundStyle(.secondary)
        } else if let item = parseProfitAmount(itemText), let shipping = shippingAmount, let rates = validRates, let units = unitsSold {
            let result = dapiProfitCheck(itemTotal: item, shippingCharged: shipping, preset: preset, rates: rates,
                                         offsiteAds: offsiteAds, unitsSold: units, orderCost: cost)
            ForEach(Array(result.lines.enumerated()), id: \.offset) { _, line in
                LabeledContent(line.label) { Text(profitMoney(line.amount)).monospacedDigit() }.font(.callout)
            }
            LabeledContent("Estimated profit") {
                Text(profitMoney(result.profit)).monospacedDigit().fontWeight(.semibold)
                    .foregroundStyle(result.profit < 0 ? .red : .primary)
            }
            if let margin = result.marginPercent {
                LabeledContent("Estimated margin") { Text(profitPercentText(margin)).monospacedDigit() }
            }
            if let note = dapiProfitCostNote(order) {
                Text(note).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Text("Not included: taxes, ads you pay for separately, currency conversion.")
                .font(.caption).foregroundStyle(.secondary)
        } else if unitsSold == nil, parseProfitAmount(itemText) != nil, shippingAmount != nil, validRates != nil {
            Text("Enter the units sold as a whole number, such as 1.").font(.callout).foregroundStyle(.orange)
        } else {
            Text("Check the highlighted amounts: use numbers like 24.99.").font(.callout).foregroundStyle(.orange)
        }
    }

    private var shippingAmount: Decimal? {
        shippingText.trimmingCharacters(in: .whitespaces).isEmpty ? 0 : parseProfitAmount(shippingText)
    }
    private var showsListingFee: Bool { preset.hasRates && preset != .shopifyBasicUS }
    private var unitsSold: Int? { showsListingFee ? parseProfitUnitsSold(unitsText) : 1 }
    private func rateValue(_ field: ProfitRateField) -> Decimal? {
        let text = rateTexts[field] ?? ""
        return field.isPercent ? parseProfitPercent(text) : parseProfitAmount(text)
    }
    private var validRates: ProfitFeeRates? {
        var rates = ProfitFeeRates()
        for field in ProfitRateField.allCases {
            guard let value = rateValue(field) else { return preset.hasRates ? nil : rates }
            rates[field] = value
        }
        return rates
    }
    private var currentRates: ProfitFeeRates {
        var rates = preset.defaultRates
        for field in ProfitRateField.allCases { if let value = rateValue(field) { rates[field] = value } }
        return rates
    }
    private func loadRatesIfNeeded() {
        guard !loadedRates else { return }
        loadedRates = true
        fillRateTexts(ProfitFeeSettings.loadRates(preset))
        if rateEditorNeedsAttention { ratesExpanded = true }
    }
    private func fillRateTexts(_ rates: ProfitFeeRates) {
        let separator = Locale.current.decimalSeparator ?? "."
        var texts: [ProfitRateField: String] = [:]
        for field in ProfitRateField.allCases {
            var text = profitRateText(rates[field])
            if separator == "," { text = text.replacingOccurrences(of: ".", with: ",") }
            texts[field] = text
        }
        rateTexts = texts
    }
    private func choosePreset(_ newPreset: ProfitFeePreset) {
        preset = newPreset
        fillRateTexts(ProfitFeeSettings.loadRates(newPreset))
        persist()
        if rateEditorNeedsAttention { ratesExpanded = true }
    }
    private func restoreDefaults() {
        ProfitFeeSettings.resetRates(preset)
        fillRateTexts(preset.defaultRates)
        persist()
    }
    /// Saves the preset and valid rates only, exactly as Slant's Profit check does; never what the buyer paid.
    private func persist() {
        ProfitFeeSettings.save(preset: preset, rates: currentRates)
    }
}

/// Report a Problem for a 3DAPI order: Copy only, never sent by Plinth.
struct DapiProblemReportSheet: View {
    @Environment(\.dismiss) private var dismiss
    let order: DapiOrder
    @State private var problem: DapiProblemKind?
    @State private var details = ""
    @State private var copied = false

    private var message: String? {
        problem.map { dapiProblemMessage(order: order, problem: $0, details: details) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Report a problem").font(.title2.weight(.bold))
            Text(dapiProblemReportCaption)
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            Picker("Problem", selection: $problem) {
                Text("Choose…").tag(DapiProblemKind?.none)
                ForEach(dapiProblemKinds(status: order.status)) { Text($0.title).tag(DapiProblemKind?.some($0)) }
            }
            .fixedSize()
            if let guidance = problem.flatMap(dapiProblemGuidance) {
                Label(guidance, systemImage: "info.circle").font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("What happened")
                TextEditor(text: $details)
                    .font(.body)
                    .frame(height: 90)
                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.secondary.opacity(0.3)))
                    .accessibilityLabel("What happened")
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Message").foregroundStyle(.secondary)
                // A fixed-height box, never a measuring layout.
                ScrollView {
                    Text(message ?? "Choose the problem to see the message.")
                        .font(.callout)
                        .foregroundStyle(message == nil ? .secondary : .primary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }
                .frame(height: 150)
                .background(Color(nsColor: .textBackgroundColor).opacity(0.6))
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.secondary.opacity(0.3)))
            }
            Spacer(minLength: 0)
            HStack {
                Button("Close", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                if copied { Text("Copied.").font(.caption).foregroundStyle(.secondary) }
                Button("Copy Message") {
                    guard let message else { return }
                    copyToPasteboard(message)
                    copied = true
                }
                .buttonStyle(.borderedProminent)
                .disabled(message == nil)
                .help(message == nil ? "Choose the problem first" : "Copy the message to paste into your email to 3DAPI")
            }
        }
        .padding(24)
        .frame(width: 540, height: 600)
        .onChange(of: problem) { copied = false }
        .onChange(of: details) { copied = false }
    }
}

// MARK: - Tools menu

/// The Orders toolbar's Tools menu for 3DAPI: Spending Report…, Export Orders…, Tracking for Your Shop…. The sheets
/// and the export live in `DapiOrdersView`, so the File menu's requests open the same ones.
struct DapiOrdersToolsMenu: View {
    /// Rows are loaded and match the filter shown (`DapiOrderListState.canUseRowsForTools`).
    let hasOrders: Bool
    @Binding var showSpendingReport: Bool
    @Binding var showTracking: Bool
    let onExport: () -> Void

    var body: some View {
        Menu {
            Button("Spending Report…") { showSpendingReport = true }
            Button("Export Orders…") { onExport() }
                .disabled(!hasOrders)
            Button("Tracking for Your Shop…") { showTracking = true }
                .disabled(!hasOrders)
        } label: {
            Label("Tools", systemImage: "chart.bar.doc.horizontal")
        }
        .help("Spending report, export and tracking for the loaded 3DAPI orders")
    }
}

/// Export Orders…: the save panel with Include customer details (off). Nothing goes to Activity or anywhere but the
/// chosen file. Returns the failure to show, or nil (saved, or the panel was cancelled).
@MainActor func dapiExportOrders(_ orders: [DapiOrder]) -> String? {
    guard !orders.isEmpty, !appIsPresentingModalUI() else { return nil }
    let panel = NSSavePanel()
    panel.title = "Export Orders"
    panel.message = orders.count == 1 ? "Exports the loaded 3DAPI order." : "Exports the \(orders.count) loaded 3DAPI orders."
    panel.nameFieldStringValue = dapiDatedFileName("3DAPI orders")
    panel.allowedContentTypes = [.commaSeparatedText]
    panel.canCreateDirectories = true
    let checkbox = NSButton(checkboxWithTitle: "Include customer details", target: nil, action: nil)
    checkbox.state = .off
    let note = NSTextField(wrappingLabelWithString: "Customer names, emails and addresses are left out unless you include them. The file isn’t protected once saved.")
    note.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
    note.textColor = .secondaryLabelColor
    note.preferredMaxLayoutWidth = 360
    let stack = NSStackView(views: [checkbox, note])
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 4
    stack.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
    panel.accessoryView = stack
    guard panel.runModal() == .OK, let destination = panel.url else { return nil }
    // A UTF-8 byte order mark lets spreadsheet apps read non-ASCII names correctly.
    let data = Data([0xEF, 0xBB, 0xBF]) + Data(dapiOrdersCSV(orders, includeCustomer: checkbox.state == .on).utf8)
    do {
        try data.write(to: destination, options: .atomic)
        return nil
    } catch {
        return error.localizedDescription
    }
}

// MARK: - Spending report sheet

struct DapiSpendingReportSheet: View {
    @Environment(\.dismiss) private var dismiss
    /// The orders loaded in the list.
    let orders: [DapiOrder]
    @StateObject private var loader = DapiSpendPeriodLoader()
    @State private var period: SpendReportPeriod = .last3Months
    @State private var copied = false
    @State private var exportError: String?

    var body: some View {
        let loaded = loader.load
        let source = loaded?.orders ?? orders
        let report = dapiSpendReport(source)
        let notes = loaded.map {
            dapiSpendPeriodNotes(complete: $0.complete, capReached: $0.capReached, loadedCount: $0.orders.count, lastCreated: $0.lastCreated)
        } ?? ["From the orders loaded in Orders. Load more there, or load the whole period here, to include older ones."]
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Spending report").font(.title2.weight(.bold))
                Text(loaded.map { "What 3DAPI charged your balance for orders created \(spendReportIntervalTitle($0.interval)), by month, in USD, after sample credit and refunds. Cancelled orders, unpaid orders and orders your buyers paid through 3DAPI’s checkout aren’t included. Nothing here is saved." }
                     ?? "What 3DAPI charged your balance for the orders loaded in Orders, by month, in USD, after sample credit and refunds. Cancelled orders, unpaid orders and orders your buyers paid through 3DAPI’s checkout aren’t included. Nothing here is saved.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                periodControls(loaded)
                ForEach(notes, id: \.self) { note in
                    Label(note, systemImage: "info.circle").font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let exclusions = dapiSpendExclusionLine(report) {
                    Text(exclusions).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(24)
            Divider()
            if report.countedOrders == 0 && report.otherCurrencies.isEmpty {
                ContentUnavailableView(loaded == nil ? "No charged orders loaded" : "No charged orders in this period",
                                       systemImage: "chart.bar",
                                       description: Text("None of these orders was paid from your 3DAPI balance and dated."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        monthsTable(report)
                        if !report.countries.isEmpty { countriesTable(report) }
                        if !report.otherCurrencies.isEmpty { otherCurrenciesTable(report) }
                    }
                    .padding(24)
                }
            }
            Divider()
            HStack {
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                if let exportError {
                    Label(exportError, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.orange).lineLimit(2)
                } else if copied {
                    Text("Copied").font(.callout).foregroundStyle(.secondary)
                }
                Button("Copy as Text") {
                    copyToPasteboard(dapiSpendReportText(report, notes: notes))
                    copied = true
                }
                .disabled(report.countedOrders == 0 && report.otherCurrencies.isEmpty)
                Button("Export CSV…") { exportCSV(report) }
                    .disabled(report.countedOrders == 0 && report.otherCurrencies.isEmpty)
            }
            .padding(20)
        }
        .frame(minWidth: 680, idealWidth: 720, minHeight: 600, idealHeight: 700)
        .onChange(of: period) { _, _ in loader.reset() }
        .onDisappear { loader.stop() }
    }

    @ViewBuilder
    private func periodControls(_ loaded: DapiSpendPeriodLoader.Load?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                Picker("Period", selection: $period) {
                    ForEach(SpendReportPeriod.allCases) { Text($0.title).tag($0) }
                }
                .fixedSize()
                .disabled(loader.running)
                if loader.running {
                    ProgressView().controlSize(.small)
                    Text(spendReportLoadProgress(loader.load?.orders.count ?? 0)).font(.callout).monospacedDigit()
                    Button("Stop") { loader.stop() }
                } else {
                    Button("Load the Whole Period") { loader.start(period) }
                        .help("Read every order created in \(spendReportIntervalTitle(spendReportPeriodInterval(period))) from 3DAPI, one page at a time")
                    if loader.canContinue {
                        Button("Continue Loading") { loader.continueLoading() }
                    }
                    if loaded != nil {
                        Button("Use Orders List") { loader.reset() }
                            .help("Show the report for the orders loaded in Orders again")
                    }
                }
            }
            if let message = loader.message {
                Text(message).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            } else if loaded == nil {
                Text("Reads every order in \(spendReportIntervalTitle(spendReportPeriodInterval(period))) from 3DAPI for this report, without changing the Orders list.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func monthsTable(_ report: DapiSpendReport) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeading(title: "By month")
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                GridRow {
                    Text("Month"); Text("Orders").gridColumnAlignment(.trailing); Text("Units").gridColumnAlignment(.trailing)
                    Text("Items").gridColumnAlignment(.trailing); Text("Shipping").gridColumnAlignment(.trailing)
                    Text("VAT").gridColumnAlignment(.trailing); Text("Credit and refunds").gridColumnAlignment(.trailing)
                    Text("Paid").gridColumnAlignment(.trailing)
                }
                .font(.caption).foregroundStyle(.secondary)
                ForEach(report.months) { month in
                    GridRow {
                        Text(dapiSpendMonthTitle(month))
                        Text("\(month.orders)").monospacedDigit()
                        VStack(alignment: .trailing, spacing: 0) {
                            Text("\(month.units)").monospacedDigit()
                            if month.ordersWithoutUnits > 0 {
                                Text("\(month.ordersWithoutUnits) unknown").font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                        Text(dapiUSDText(month.items)).monospacedDigit()
                        Text(dapiUSDText(month.shipping)).monospacedDigit()
                        Text(dapiUSDText(month.vat)).monospacedDigit()
                        Text(profitMoney(-(month.sampleCredit + month.refunds))).monospacedDigit()
                        Text(dapiUSDText(month.totalPaid)).monospacedDigit().fontWeight(.semibold)
                    }
                }
                Divider().gridCellUnsizedAxes(.horizontal)
                GridRow {
                    Text("Total").fontWeight(.semibold)
                    Text("\(report.countedOrders)").monospacedDigit().fontWeight(.semibold)
                    Text("\(report.units)").monospacedDigit().fontWeight(.semibold)
                    Text(""); Text(""); Text(""); Text("")
                    Text(dapiUSDText(report.totalPaid)).monospacedDigit().fontWeight(.semibold)
                }
            }
            .textSelection(.enabled)
            if report.months.contains(where: { $0.ordersWithoutUnits > 0 }) {
                Text("Units are counted only for orders read with their lines; Load the Whole Period reads them.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func countriesTable(_ report: DapiSpendReport) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeading(title: "Shipping by destination country")
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                GridRow {
                    Text("Country"); Text("Orders").gridColumnAlignment(.trailing); Text("Average").gridColumnAlignment(.trailing)
                    Text("Range").gridColumnAlignment(.trailing)
                }
                .font(.caption).foregroundStyle(.secondary)
                ForEach(report.countries) { entry in
                    GridRow {
                        Text(spendReportCountryTitle(entry.countryCode)).lineLimit(2)
                        Text("\(entry.orders)").monospacedDigit()
                        Text(dapiUSDText(entry.average)).monospacedDigit().fontWeight(.semibold)
                        Text(dapiSpendRangeText(entry)).monospacedDigit()
                    }
                }
            }
            .textSelection(.enabled)
            Text("What 3DAPI charged to ship each order, excluding VAT: a guide for your shop’s shipping profiles. Orders with more or larger items usually cost more to send.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if report.withoutCountry > 0 {
                Text("\(report.withoutCountry == 1 ? "1 order has" : "\(report.withoutCountry) orders have") no destination country Plinth can read.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func otherCurrenciesTable(_ report: DapiSpendReport) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeading(title: "Other currencies", caption: "Not converted or added to the USD figures")
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                GridRow {
                    Text("Currency"); Text("Orders").gridColumnAlignment(.trailing); Text("Paid").gridColumnAlignment(.trailing)
                }
                .font(.caption).foregroundStyle(.secondary)
                ForEach(report.otherCurrencies) { entry in
                    GridRow {
                        Text(entry.currency)
                        Text("\(entry.orders)").monospacedDigit()
                        Text(dapiSpendOtherCurrencyText(entry)).monospacedDigit()
                    }
                }
            }
            .textSelection(.enabled)
        }
    }

    private func exportCSV(_ report: DapiSpendReport) {
        let panel = NSSavePanel()
        panel.title = "Export Spending Report"
        panel.nameFieldStringValue = dapiDatedFileName("3DAPI spending")
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        exportError = nil
        let data = Data([0xEF, 0xBB, 0xBF]) + Data(dapiSpendReportCSV(report).utf8)
        do {
            try data.write(to: destination, options: .atomic)
        } catch {
            // Shown in the sheet: a window alert behind it would wait until the sheet closes.
            exportError = "Not exported: \(error.localizedDescription)"
        }
    }
}

// MARK: - Tracking sheet

struct DapiTrackingSheet: View {
    @Environment(\.dismiss) private var dismiss
    let orders: [DapiOrder]
    @ObservedObject private var tools = DapiOrderToolsState.shared
    @ObservedObject private var shopify = ShopifyConnection.shared
    @State private var showDone = false
    @State private var copiedAll = false

    var body: some View {
        let groups = dapiTrackingGroups(orders, done: tools.trackingDoneIDs, showDone: showDone)
        let waiting = groups.listed.filter { !tools.trackingDoneIDs.contains($0.id) }
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Tracking for your shop").font(.title2.bold())
                Text("Orders 3DAPI has shipped, with their carrier and tracking number, to copy into Etsy or Shopify. 3DAPI gives no tracking link. Mark an order as done once you’ve added its tracking in your shop; marks last until you quit Plinth. Only loaded orders are listed.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                // Only when Shopify is connected: otherwise there's nothing it could have offered.
                if shopify.isConfigured {
                    Text(dapiTrackingNoShopifyNote)
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if groups.listed.isEmpty {
                ContentUnavailableView {
                    Label(groups.doneCount > 0 ? "All orders marked as done" : "No tracking yet", systemImage: "shippingbox")
                } description: {
                    Text(groups.doneCount > 0
                         ? "Every loaded order with tracking is marked as done in your shop. Show marked orders lists them again."
                         : "None of the loaded orders has tracking from 3DAPI yet. Refresh Orders later to check again.")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    if !groups.withReference.isEmpty {
                        Section("Orders with a reference") { ForEach(groups.withReference) { row($0) } }
                    }
                    if !groups.withoutReference.isEmpty {
                        Section("Other orders") { ForEach(groups.withoutReference) { row($0) } }
                    }
                }
                .frame(minHeight: 240)
            }
            HStack {
                Button("Copy All") {
                    copyToPasteboard(dapiTrackingCopyAllText(waiting))
                    copiedAll = true
                }
                .disabled(waiting.isEmpty)
                .help(waiting.isEmpty ? "No orders with tracking are waiting" : "Copy each listed order’s reference and tracking, one per line")
                if copiedAll { Text("Copied").font(.caption).foregroundStyle(.secondary) }
                if groups.doneCount > 0 {
                    Toggle("Show marked orders (\(groups.doneCount))", isOn: $showDone).toggleStyle(.checkbox)
                }
                Spacer()
                // Marks apply as they're made, so Done; Escape closes the sheet.
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(minWidth: 620, idealWidth: 700, minHeight: 440, idealHeight: 560)
    }

    private func row(_ entry: DapiTrackingEntry) -> some View {
        let done = Binding(
            get: { tools.trackingDoneIDs.contains(entry.id) },
            set: { ticked in
                if ticked { tools.trackingDoneIDs.insert(entry.id) } else { tools.trackingDoneIDs.remove(entry.id) }
                copiedAll = false
            })
        return HStack(alignment: .firstTextBaseline, spacing: 10) {
            Toggle("Done in your shop", isOn: done)
                .toggleStyle(.checkbox)
                .labelsHidden()
                .accessibilityLabel("Marked as done in your shop, \(dapiTrackingTitle(entry))")
                .help("Mark as done once you’ve added this order’s tracking in your shop (this session only)")
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(dapiTrackingTitle(entry)).font(.body.weight(.medium)).textSelection(.enabled)
                    if entry.reference != nil {
                        Text("· \(entry.number)").foregroundStyle(.secondary)
                    }
                    Text("· \(entry.status.label)").foregroundStyle(.secondary)
                }
                .lineLimit(1)
                Text(entry.carrier.map { "\($0) \(entry.trackingNumber)" } ?? entry.trackingNumber)
                    .font(.callout.monospaced()).textSelection(.enabled).lineLimit(2)
            }
            Spacer(minLength: 8)
            Button("Copy") { copyToPasteboard(dapiTrackingCopyText(entry)) }
                .help("Copy “\(dapiTrackingCopyText(entry))”")
        }
        .padding(.vertical, 2)
    }
}
