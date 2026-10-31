import AppKit
import SwiftUI

// The Orders section when 3DAPI is the print service: the list (DapiOrderList.swift), the order detail, and the entry
// points to the composer (DapiOrderComposerView.swift) and the cancel review (DapiPlaceOrderSheet.swift). Reading
// orders is read-only; only Place Order in the review and Cancel Order in the cancel review write, each after an
// explicit click. No menu item or keyboard shortcut here sends anything.

/// Activity for the 3DAPI order screens: titles and status words only (never numbers, references, prices or names).
@MainActor func dapiOrderActivityLogger(_ store: StudioStore) -> (String, String, Bool) -> Void {
    { [weak store] title, detail, success in
        guard let store else { return }
        store.activities.insert(Activity(title: title, detail: detail, success: success), at: 0)
        store.activities = Array(store.activities.prefix(100))
    }
}

/// "23 Oct 2026".
func dapiOrderDateText(_ date: Date?) -> String {
    date?.formatted(.dateTime.day().month(.abbreviated).year()) ?? "—"
}

/// "23 Oct 2026 at 14:05".
func dapiOrderDateTimeText(_ date: Date?) -> String {
    date?.formatted(date: .abbreviated, time: .shortened) ?? "—"
}

/// Units in the order: the lines' quantities when they were read, else 3DAPI's item count.
func dapiOrderUnits(_ order: DapiOrder) -> Int {
    guard let items = order.items, !items.isEmpty else { return order.itemCount }
    return items.reduce(0) { $0 + max(0, $1.quantity) }
}

/// "GB", the country name, or a dash.
func dapiOrderCountryText(_ order: DapiOrder) -> String {
    if let code = order.countryCode, !code.isEmpty { return code.uppercased() }
    return order.countryName ?? "—"
}

/// A line's materials as 3DAPI named them ("Slot 1: PLA Red"), or the IDs when no name came back.
func dapiOrderItemMaterialsText(_ item: DapiOrderItem) -> String {
    guard !item.materials.isEmpty else { return "—" }
    let single = item.materials.count == 1
    return item.materials.sorted { $0.slot < $1.slot }.map { slot in
        let name = slot.materialName ?? slot.materialID
        return single ? name : "Slot \(slot.slot): \(name)"
    }.joined(separator: ", ")
}

/// "20%" for a VAT rate of 0.2.
func dapiVATRateText(_ rate: Decimal) -> String {
    let percent = NSDecimalNumber(decimal: rate * 100).doubleValue
    return percent.formatted(.number.precision(.fractionLength(0...2))) + "%"
}

/// The notice above the list about whether this account can order, or nil when it can (or before the first check).
func dapiOrdersAccountNotice(configured: Bool, checked: Bool, account: DapiAccount?, onboarding: DapiOnboarding?,
                             checkFailure: String?) -> String? {
    guard configured else { return "Add a 3DAPI integrator key in Settings › Account to see and place 3DAPI orders." }
    guard checked else { return nil }
    guard let account else {
        return "Plinth couldn’t check your 3DAPI account" + (checkFailure.map { ": \($0)" } ?? ".")
    }
    return dapiOrderingProblem(account: account, onboardingOrderBlockers: onboarding?.orderBlockers ?? [])
}

/// The composer's starting point: a Models request, a duplicated order, or nothing.
struct DapiComposerSeed: Identifiable, Equatable {
    let id = UUID()
    var prefill: DapiComposerPrefill?
    var duplicateOf: DapiOrder?
}

/// What the cancel review is for: the order as the detail showed it.
struct DapiCancelRequest: Identifiable, Equatable {
    var id: String { orderID }
    let orderID: String
    let number: String
    let shownStatus: DapiOrderStatus
}

/// Shown by `StudioView` for `.orders` while `PrintServiceChoice.shared.service == .dapi`.
struct DapiOrdersView: View {
    @EnvironmentObject var store: StudioStore
    @ObservedObject private var connection = DapiConnection.shared
    @ObservedObject private var session = DapiOrderSession.shared
    @ObservedObject private var nameIndex = DapiModelNameIndex.shared
    @StateObject private var list = DapiOrderListState(environment: .live())
    @State private var searchText = ""
    @State private var composer: DapiComposerSeed?
    @State private var cancelRequest: DapiCancelRequest?
    @State private var accountChecked = false
    @State private var accountCheckFailure: String?

    private var accountNotice: String? {
        dapiOrdersAccountNotice(configured: connection.isConfigured, checked: accountChecked, account: connection.account,
                                onboarding: connection.onboarding, checkFailure: accountCheckFailure)
    }
    private var newOrderBlockedReason: String? {
        if !connection.isConfigured { return "Add a 3DAPI key in Settings first." }
        if composer != nil || cancelRequest != nil { return "Close the open 3DAPI order sheet first." }
        return nil
    }

    var body: some View {
        Group {
            if !connection.isConfigured {
                ContentUnavailableView {
                    Label("Add a 3DAPI key", systemImage: "key")
                } description: {
                    Text("Save a 3DAPI integrator key in Settings › Account to see and place orders on 3DAPI.")
                } actions: {
                    Button("Open Settings") { store.requestSettings(.account) }
                }
            } else {
                HSplitView {
                    listPane
                        .frame(minWidth: 380, idealWidth: 560, maxWidth: .infinity, maxHeight: .infinity)
                    detailPane
                        .frame(minWidth: 460, idealWidth: 560, maxWidth: .infinity, maxHeight: .infinity)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) { notices }
        .searchable(text: $searchText, prompt: "Search number or reference")
        .task(id: searchText) {
            // Debounced: 3DAPI searches part of the number or reference on its side.
            do { try await Task.sleep(nanoseconds: 500_000_000) } catch { return }
            if connection.isConfigured { list.applySearch(searchText) }
        }
        .toolbar { toolbarContent }
        .onAppear {
            list.log = dapiOrderActivityLogger(store)
            // The seller is looking at Orders: the sidebar badge has done its job (DapiOrderWatch.swift).
            DapiOrderWatch.shared.ordersViewed()
            if connection.isConfigured, !list.loaded, !list.loading { list.reload() }
            checkAccountIfNeeded()
            consumeComposerRequest()
        }
        // Reads stop when the screen goes away; loaded orders stay for when it comes back.
        .onDisappear { list.cancel() }
        .onChange(of: connection.isConfigured) { _, configured in
            list.forgetAll()
            accountChecked = false
            if configured { list.reload(); checkAccountIfNeeded() }
        }
        .onChange(of: connection.account) { old, new in
            // Another account's key: its orders aren't this one's.
            if let old, let new, old != new { list.forgetAll(); list.reload() }
            if new != nil { accountChecked = true; accountCheckFailure = nil }
        }
        .onChange(of: session.composerRequest) { _, _ in consumeComposerRequest() }
        .onChange(of: composer) { _, new in if new == nil { consumeComposerRequest() } }
        .sheet(item: $composer) { seed in
            DapiOrderComposerView(seed: seed, onPlaced: { order in list.insertAndSelect(order) },
                                  onFound: { order in list.insertAndSelect(order) })
                .environmentObject(store)
        }
        .sheet(item: $cancelRequest) { request in
            DapiCancelOrderSheet(request: request) { order in list.apply(order) }
                .environmentObject(store)
        }
    }

    private func checkAccountIfNeeded() {
        guard connection.isConfigured else { return }
        if connection.account != nil { accountChecked = true; return }
        Task {
            let failure = await connection.refreshStatus()
            accountCheckFailure = failure
            accountChecked = true
        }
    }

    /// Opens the composer for Models' request (Order with 3DAPI…, Order a Sample to Me) when no sheet is open.
    private func consumeComposerRequest() {
        guard let request = session.composerRequest, composer == nil, cancelRequest == nil, connection.isConfigured else { return }
        session.composerRequest = nil
        composer = DapiComposerSeed(prefill: request)
    }

    // MARK: Notices

    @ViewBuilder
    private var notices: some View {
        VStack(spacing: 0) {
            if connection.isConfigured, let accountNotice {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Label(accountNotice, systemImage: "info.circle")
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button("Open Settings") { store.requestSettings(.account) }
                        .controlSize(.small)
                }
                .padding(.horizontal, 16).padding(.vertical, 8)
                .background(.bar)
                Divider()
            }
            if !session.unconfirmedOrders.isEmpty {
                DapiUnconfirmedOrdersNotice { order in list.insertAndSelect(order) }
                    .padding(.horizontal, 16).padding(.vertical, 8)
                    .background(.bar)
                Divider()
            }
        }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            // Opens the composer only; nothing is sent until Place Order in the review.
            Button("New 3DAPI Order…") { composer = DapiComposerSeed() }
                .disabled(newOrderBlockedReason != nil)
                .help(newOrderBlockedReason ?? "Compose an order to place on 3DAPI. Nothing is charged until you review it and press Place Order.")
        }
        ToolbarItem(placement: .automatic) {
            Menu {
                // A status applies at once (a fresh read of page 1).
                Picker("Status", selection: Binding(
                    get: { list.status?.raw ?? "" },
                    set: { raw in list.applyStatus(raw.isEmpty ? nil : DapiOrderStatus(raw: raw)) }
                )) {
                    Text("All Statuses").tag("")
                    Divider()
                    ForEach(DapiOrderStatus.known, id: \.raw) { Text($0.label).tag($0.raw) }
                }
                .pickerStyle(.inline)
                .labelsHidden()
                .disabled(!connection.isConfigured)
            } label: {
                Label("Status", systemImage: list.status != nil
                      ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
            }
            .help("Show 3DAPI orders with this status")
        }
        ToolbarItem(placement: .automatic) {
            Button {
                list.reload()
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .disabled(!connection.isConfigured || list.loading)
            .help("Read the newest 3DAPI orders again")
        }
        ToolbarItem(placement: .automatic) {
            DapiOrdersToolsMenu(orders: list.orders)
        }
    }

    // MARK: List

    private var listPane: some View {
        VStack(spacing: 0) {
            Table(list.orders, selection: $list.selection) {
                TableColumn("Number") { (order: DapiOrder) in
                    Text(order.number).lineLimit(1).truncationMode(.middle).help(order.number)
                }
                .width(min: 70, ideal: 100)
                TableColumn("Status") { (order: DapiOrder) in
                    HStack(spacing: 4) {
                        Text(order.status.label).lineLimit(1)
                        if let attention = dapiOrderAttention(order) {
                            Image(systemName: "exclamationmark.circle.fill")
                                .foregroundStyle(.orange)
                                .help(attention)
                                .accessibilityLabel("Needs attention: \(attention)")
                        }
                    }
                    .help(order.status.meaning)
                }
                .width(min: 70, ideal: 110, max: 160)
                TableColumn("Created") { (order: DapiOrder) in
                    Text(dapiOrderDateText(order.createdAt)).lineLimit(1)
                }
                .width(min: 84, ideal: 96, max: 130)
                TableColumn("Units") { (order: DapiOrder) in
                    Text("\(dapiOrderUnits(order))").monospacedDigit()
                }
                .width(min: 36, ideal: 44, max: 70)
                TableColumn("Country") { (order: DapiOrder) in
                    Text(dapiOrderCountryText(order)).lineLimit(1)
                        .help(order.countryCode.map { dapiCountryName($0.uppercased()) } ?? "")
                }
                .width(min: 44, ideal: 56, max: 120)
                TableColumn("Total") { (order: DapiOrder) in
                    Text(order.charges.map { dapiMoneyText($0.total) } ?? "—").monospacedDigit().lineLimit(1)
                }
                .width(min: 56, ideal: 72, max: 120)
                TableColumn("Reference") { (order: DapiOrder) in
                    Text(order.reference ?? "—").foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        .help(order.reference ?? "")
                }
                .width(min: 60, ideal: 120)
            }
            .contextMenu(forSelectionType: String.self) { ids in
                if ids.count == 1, let id = ids.first, let order = list.orders.first(where: { $0.id == id }) {
                    Button("Duplicate as New Order…") { composer = DapiComposerSeed(duplicateOf: order) }
                        .disabled(newOrderBlockedReason != nil || (order.items ?? []).isEmpty)
                    Button("Copy Order Number") { copyToPasteboard(order.number) }
                }
            }
            .overlay { emptyOverlay }
            if let error = list.loadError {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button("Try Reading Again") { list.reload() }
                        .controlSize(.small)
                        .disabled(list.loading)
                }
                .padding(.horizontal, 16).padding(.top, 6)
            }
            if list.loading {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Reading 3DAPI orders…").font(.caption).foregroundStyle(.secondary)
                }
                .padding(8)
            } else if list.hasMore {
                Button("Load More") { list.loadMore() }
                    .padding(8)
                    .help("Read the next page of older orders")
            }
        }
    }

    @ViewBuilder
    private var emptyOverlay: some View {
        if list.loaded, list.orders.isEmpty, !list.loading, list.loadError == nil {
            if !list.appliedSearch.isEmpty {
                ContentUnavailableView.search(text: list.appliedSearch)
            } else if let text = dapiOrdersEmptyText(status: list.status, search: "") {
                ContentUnavailableView {
                    Label(text.title, systemImage: "shippingbox")
                } description: {
                    Text(text.detail)
                } actions: {
                    if list.status != nil {
                        Button("Show All Orders") { searchText = ""; list.showAll() }
                    }
                }
            }
        }
    }

    // MARK: Detail

    @ViewBuilder
    private var detailPane: some View {
        if let order = list.selectedOrder {
            DapiOrderDetailView(
                order: order,
                refreshing: list.refreshingOrderID == order.id,
                refreshError: list.refreshingOrderID == nil ? list.orderRefreshError : nil,
                cancelUnknown: session.cancelOutcomeUnknown.contains(order.id),
                modelNames: nameIndex.names,
                onRefresh: { list.refreshOrder(id: order.id) },
                onDuplicate: { composer = DapiComposerSeed(duplicateOf: order) },
                duplicateBlockedReason: newOrderBlockedReason,
                onCancel: { cancelRequest = DapiCancelRequest(orderID: order.id, number: order.number, shownStatus: order.status) })
            .id(order.id)
            .task(id: order.id) {
                // Names lines quoted from library models ("Plinth <hex>"), hashing files in the background.
                if (order.items ?? []).contains(where: { dapiIsNeutralQuoteName($0.quoteName) && nameIndex.names[$0.quoteName ?? ""] == nil }) {
                    nameIndex.refresh(models: store.localModels)
                }
            }
        } else {
            ContentUnavailableView("Select an order", systemImage: "shippingbox",
                                   description: Text("Choose a 3DAPI order from the list to see its details."))
        }
    }
}

/// One 3DAPI order: status, delivery, lines, charges, refunds, shipping and the actions.
struct DapiOrderDetailView: View {
    let order: DapiOrder
    let refreshing: Bool
    let refreshError: String?
    let cancelUnknown: Bool
    let modelNames: [String: String]
    let onRefresh: () -> Void
    let onDuplicate: () -> Void
    let duplicateBlockedReason: String?
    let onCancel: () -> Void

    private var canOfferCancel: Bool { order.status.canRequestCancellation && !cancelUnknown }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                actions
                if cancelUnknown {
                    Label("A cancellation of this order didn’t get a clear answer, so it may or may not be cancelled. Refresh this order to see its status; Plinth won’t send another cancellation meanwhile.",
                          systemImage: "questionmark.circle")
                        .font(.callout).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let refreshError {
                    Label(refreshError, systemImage: "exclamationmark.triangle")
                        .font(.callout).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                delivery
                lines
                charges
                refunds
                shipping
                DapiOrderInsightsSection(order: order)
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(order.number).font(.title2.weight(.semibold)).textSelection(.enabled)
                Spacer()
                Text(order.status.label)
                    .font(.callout.weight(.semibold))
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Capsule().fill(Color.secondary.opacity(0.15)))
            }
            Text(order.status.meaning).font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let attention = dapiOrderAttention(order) {
                Label(attention, systemImage: "exclamationmark.circle.fill")
                    .font(.callout).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                GridRow {
                    Text("Created").foregroundStyle(.secondary)
                    Text(dapiOrderDateTimeText(order.createdAt))
                }
                GridRow {
                    Text("Updated").foregroundStyle(.secondary)
                    Text(dapiOrderDateTimeText(order.updatedAt))
                }
                if let reference = order.reference, !reference.isEmpty {
                    GridRow {
                        Text("Reference").foregroundStyle(.secondary)
                        Text(reference).textSelection(.enabled)
                    }
                }
            }
            .font(.callout)
        }
    }

    private var actions: some View {
        HStack(spacing: 10) {
            Button {
                onRefresh()
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .disabled(refreshing)
            .help("Read this order from 3DAPI again")
            if refreshing { ProgressView().controlSize(.small) }
            Button("Duplicate as New Order…") { onDuplicate() }
                .disabled(duplicateBlockedReason != nil || (order.items ?? []).isEmpty)
                .help(duplicateBlockedReason ?? ((order.items ?? []).isEmpty
                      ? "This order’s lines weren’t read, so they can’t be copied."
                      : "Start a new order with the same models, quantities and materials. The address isn’t copied."))
            Button("Copy Number") { copyToPasteboard(order.number) }
            Spacer()
            // Last, and only while 3DAPI still lets the order be cancelled. It opens the cancel review only.
            if canOfferCancel {
                Button("Cancel Order…", role: .destructive) { onCancel() }
                    .help("Review cancelling this order. 3DAPI refunds a paid order in full to your wallet.")
            }
        }
    }

    @ViewBuilder
    private var delivery: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Deliver to").font(.headline)
            let country = order.countryName ?? order.countryCode.map { dapiCountryName($0.uppercased()) }
            if let name = order.customerName, !name.isEmpty { Text(name).textSelection(.enabled) }
            if let email = order.customerEmail, !email.isEmpty { Text(email).textSelection(.enabled).foregroundStyle(.secondary) }
            if let address = order.formattedAddress, !address.isEmpty {
                Text(address).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            } else {
                let place = [order.city, country].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", ")
                Text(place.isEmpty ? "—" : place)
            }
            if order.formattedAddress == nil, order.customerName == nil {
                Text("3DAPI shows the full address and customer only to keys with orders:read_customer, which Plinth doesn’t need.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private var lines: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Items").font(.headline)
            if let items = order.items, !items.isEmpty {
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                    GridRow {
                        Text("Model"); Text("Materials"); Text("Qty"); Text("Unit price"); Text("Total")
                    }
                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Divider().gridCellUnsizedAxes(.horizontal)
                    ForEach(items) { item in
                        GridRow(alignment: .top) {
                            Text(dapiLineDisplayName(quoteName: item.quoteName, modelNames: modelNames))
                                .lineLimit(2).help(item.quoteName ?? item.quoteID)
                            Text(dapiOrderItemMaterialsText(item)).font(.callout).fixedSize(horizontal: false, vertical: true)
                            Text("\(item.quantity)").monospacedDigit()
                            Text(item.unitPrice.map(dapiMoneyText) ?? "—").monospacedDigit()
                            Text(item.total.map(dapiMoneyText) ?? "—").monospacedDigit()
                        }
                    }
                }
                .font(.callout)
            } else if order.items == nil {
                Text("\(order.itemCount) \(order.itemCount == 1 ? "item" : "items"). Refresh to read the lines.")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                Text("3DAPI listed no lines for this order.").font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var charges: some View {
        if let charges = order.charges {
            VStack(alignment: .leading, spacing: 6) {
                Text("Charges").font(.headline)
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
                    row("Items", dapiMoneyText(charges.items))
                    row("Shipping", dapiMoneyText(charges.shipping))
                    if charges.vat.amountMinor != 0 || charges.vatRate != 0 {
                        let rate = dapiVATRateText(charges.vatRate)
                        let country = charges.vatCountry.map { " · \($0.uppercased())" } ?? ""
                        row("VAT (\(rate)\(country))", dapiMoneyText(charges.vat) + (charges.vatIncluded ? " included" : ""))
                    } else {
                        row("VAT", "None")
                    }
                    if let credit = charges.sampleCredit, credit.amountMinor != 0 {
                        row("Sample credit", "−" + dapiMoneyText(credit))
                    }
                    row("Total", dapiMoneyText(charges.total), bold: true)
                    row("Paid by", dapiPaidByText(charges.paidBy))
                }
                .font(.callout)
            }
        }
    }

    @ViewBuilder
    private var refunds: some View {
        if !order.refunds.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("Refunds").font(.headline)
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
                    ForEach(order.refunds, id: \.id) { refund in
                        row(dapiOrderDateText(refund.createdAt), dapiMoneyText(refund.amount))
                    }
                }
                .font(.callout)
            }
        }
    }

    @ViewBuilder
    private var shipping: some View {
        let ship = order.shipping
        if ship.tier != nil || ship.carrier != nil || ship.trackingNumber != nil || ship.shippedAt != nil {
            VStack(alignment: .leading, spacing: 6) {
                Text("Shipping").font(.headline)
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
                    if let tier = ship.tier { row("Parcel size", tier.capitalized) }
                    if let carrier = ship.carrier { row("Carrier", carrier) }
                    if let shippedAt = ship.shippedAt { row("Shipped", dapiOrderDateTimeText(shippedAt)) }
                    if let tracking = ship.trackingNumber, !tracking.isEmpty {
                        GridRow {
                            Text("Tracking number").foregroundStyle(.secondary)
                            HStack(spacing: 8) {
                                Text(tracking).textSelection(.enabled).monospaced()
                                Button("Copy") { copyToPasteboard(tracking) }.controlSize(.small)
                            }
                        }
                    }
                }
                .font(.callout)
                if ship.trackingNumber != nil {
                    Text("3DAPI gives no tracking link: look the number up on the carrier’s site.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func row(_ label: String, _ value: String, bold: Bool = false) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value).monospacedDigit().fontWeight(bold ? .semibold : .regular).textSelection(.enabled)
        }
    }
}

/// "You (wallet)", "Buyer", "3DAPI", or as sent.
func dapiPaidByText(_ paidBy: String) -> String {
    switch paidBy.lowercased() {
    case "you": "You (wallet)"
    case "buyer": "Buyer"
    case "dapi": "3DAPI"
    default: paidBy
    }
}

/// The session's unconfirmed 3DAPI orders, each named, with Look for Order on 3DAPI (read-only, by exact reference).
/// Found orders are confirmed and handed to `onFound`; not-found ones stay. Used by the Orders list and the composer.
struct DapiUnconfirmedOrdersNotice: View {
    @ObservedObject private var session = DapiOrderSession.shared
    /// Only these attempts (the review's own), or every unconfirmed attempt when nil.
    var only: Set<UUID>? = nil
    let onFound: (DapiOrder) -> Void
    @State private var looking = false
    @State private var summary: String?
    @State private var task: Task<Void, Never>?

    private var attempts: [DapiUnconfirmedOrder] {
        session.unconfirmedOrders.filter { only == nil || only!.contains($0.id) }
    }

    var body: some View {
        if !attempts.isEmpty || summary != nil {
            VStack(alignment: .leading, spacing: 6) {
                if !attempts.isEmpty {
                    Label(attempts.count == 1
                          ? "This order was sent without a clear answer. 3DAPI may have charged and placed it:"
                          : "These orders were sent without a clear answer. 3DAPI may have charged and placed them:",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.callout).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                    ForEach(attempts) { attempt in
                        Text(dapiUnconfirmedOrderLine(attempt)).font(.callout).padding(.leading, 20)
                    }
                }
                HStack(spacing: 8) {
                    if !attempts.isEmpty {
                        Button("Look for Order on 3DAPI") { lookFor(attempts) }
                            .disabled(looking)
                            .help("Search your 3DAPI orders for these attempts’ references. Nothing is sent or placed.")
                    }
                    if looking { ProgressView().controlSize(.small) }
                    if let summary {
                        Text(summary).font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .onDisappear { task?.cancel(); task = nil; looking = false }
        }
    }

    private func lookFor(_ attempts: [DapiUnconfirmedOrder]) {
        guard !looking else { return }
        let client: any DapiOrdering
        do { client = try DapiConnection.shared.currentOrderingClient() } catch {
            summary = dapiFailureMessage(error)
            return
        }
        looking = true
        summary = nil
        task = Task {
            let results = await dapiLookForOrders(attempts, client: client,
                                                  pause: { try await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000)) },
                                                  confirm: { DapiOrderSession.shared.confirmUnconfirmedOrder(reference: $0) })
            looking = false
            task = nil
            let ordered = attempts.compactMap { results[$0.id] }
            for case .found(let order) in ordered.reversed() { onFound(order) }
            summary = dapiOrderLookupSummary(ordered)
        }
    }
}
