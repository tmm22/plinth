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

/// Units shown in the list: the lines' quantities when they were read, else 3DAPI's item count. (`dapiOrderUnits` is
/// the strict count, nil without lines.)
func dapiOrderListUnits(_ order: DapiOrder) -> Int {
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
    /// "wallet" or "checkout": where a refund goes (`dapiCancelExplanation`).
    var mode: String = "wallet"
}

/// The empty list's way back when a typed search and a status filter together left it empty.
enum DapiOrdersEmptyAction: Equatable { case clearSearch, showAll }

/// The ways back the empty list offers: Clear Search for a search, Show All Orders for a status filter (both when
/// both are applied). None for an unfiltered empty list.
func dapiOrdersEmptyActions(status: DapiOrderStatus?, search: String) -> [DapiOrdersEmptyAction] {
    var actions: [DapiOrdersEmptyAction] = []
    if !search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { actions.append(.clearSearch) }
    if status != nil { actions.append(.showAll) }
    return actions
}

/// Counts a 3DAPI order sheet in `DapiOrderSession.openSheets` while it is shown (once per appearance, released on every
/// disappearance), so the 3DAPI key and the print service can't change under it.
struct DapiOrderSheetCounted: ViewModifier {
    @State private var registered = false

    func body(content: Content) -> some View {
        content
            .onAppear {
                guard !registered else { return }
                registered = true
                DapiOrderSession.shared.sheetOpened()
            }
            .onDisappear {
                guard registered else { return }
                registered = false
                DapiOrderSession.shared.sheetClosed()
            }
    }
}

extension View {
    /// See `DapiOrderSheetCounted`.
    func dapiOrderSheetCounted() -> some View { modifier(DapiOrderSheetCounted()) }
}

/// Shown by `StudioView` for `.orders` while `PrintServiceChoice.shared.service == .dapi`.
struct DapiOrdersView: View {
    @EnvironmentObject var store: StudioStore
    @ObservedObject private var connection = DapiConnection.shared
    @ObservedObject private var session = DapiOrderSession.shared
    @ObservedObject private var nameIndex = DapiModelNameIndex.shared
    /// Shared, so the loaded orders outlive a visit to another section; forgotten on a new key (`keyGeneration`).
    @ObservedObject private var list = DapiOrderListState.shared
    @State private var searchText = ""
    @State private var composer: DapiComposerSeed?
    @State private var cancelRequest: DapiCancelRequest?
    @State private var accountChecked = false
    @State private var accountCheckFailure: String?
    // The Tools menu's sheets, here so the File menu's requests (`DapiOrderSession.toolRequest`) open the same ones.
    @State private var showSpendingReport = false
    @State private var showTracking = false
    @State private var exportError: String?

    private var accountNotice: String? {
        dapiOrdersAccountNotice(configured: connection.isConfigured, checked: accountChecked, account: connection.account,
                                onboarding: connection.onboarding, checkFailure: accountCheckFailure)
    }
    private var newOrderBlockedReason: String? {
        if !connection.isConfigured { return "Add a 3DAPI key in Settings first." }
        if composer != nil || cancelRequest != nil { return "Close the open 3DAPI order sheet first." }
        return nil
    }
    private var anySheetShown: Bool { composer != nil || cancelRequest != nil || showSpendingReport || showTracking }

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
            // The search the list holds from an earlier visit.
            if searchText != list.appliedSearch { searchText = list.appliedSearch }
            // The seller is looking at Orders: the sidebar badge has done its job (DapiOrderWatch.swift).
            DapiOrderWatch.shared.ordersViewed()
            // The key changed while Orders wasn't shown: the earlier key's orders aren't this one's. Otherwise the
            // orders loaded on an earlier visit stay, and only a list never read (or whose read was stopped) is read.
            list.keyChanged(generation: connection.keyGeneration, configured: connection.isConfigured)
            checkAccountIfNeeded()
            consumeComposerRequest()
            consumeOrderToShow()
            consumeToolRequest()
        }
        // Reads stop when the screen goes away; loaded orders stay for when it comes back.
        .onDisappear { list.cancel() }
        // Saved, replaced or removed: the earlier key's orders go, and replies for it are dropped, even when the new
        // key looks like the same account. (A different account always comes with a new key, so the account itself
        // isn't compared: an approval or scope change keeps the orders.)
        .onChange(of: connection.keyGeneration) { _, generation in
            list.keyChanged(generation: generation, configured: connection.isConfigured)
            accountChecked = false
            accountCheckFailure = nil
            checkAccountIfNeeded()
        }
        .onChange(of: connection.account) { _, new in
            if new != nil { accountChecked = true; accountCheckFailure = nil }
        }
        // Showing a specific order clears a filter it doesn't match (`DapiOrderListState.show`): the field follows.
        .onChange(of: list.appliedSearch) { _, applied in
            if applied.isEmpty, !searchText.isEmpty { searchText = "" }
        }
        .onChange(of: session.composerRequest) { _, _ in consumeComposerRequest() }
        .onChange(of: session.orderToShow) { _, _ in consumeOrderToShow() }
        .onChange(of: session.toolRequest) { _, _ in consumeToolRequest() }
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
        // Only rows read with the filter shown (`canUseRowsForTools`) reach the tools. Both sheets count as 3DAPI order
        // sheets, so the key and the print service can't change under them.
        .sheet(isPresented: $showSpendingReport) {
            DapiSpendingReportSheet(orders: list.canUseRowsForTools ? list.orders : []).dapiOrderSheetCounted()
        }
        .sheet(isPresented: $showTracking) {
            DapiTrackingSheet(orders: list.canUseRowsForTools ? list.orders : []).dapiOrderSheetCounted()
        }
        .alert("Couldn’t export the orders", isPresented: Binding(get: { exportError != nil }, set: { if !$0 { exportError = nil } })) {
            Button("OK", role: .cancel) { exportError = nil }
        } message: {
            Text(exportError ?? "")
        }
    }

    /// A clicked 3DAPI order notification: read that order by ID (read-only), show it first in the list and select it.
    /// Ignored without a key.
    private func consumeOrderToShow() {
        guard let id = session.orderToShow else { return }
        session.orderToShow = nil
        guard connection.isConfigured, dapiOrderIDIsSafe(id) else { return }
        list.show(orderID: id)
    }

    /// The File menu's 3DAPI commands: the same actions as the toolbar's Refresh and Tools menu. Ignored without a key
    /// or while a sheet is shown (menu commands never act over a sheet).
    private func consumeToolRequest() {
        guard let request = session.toolRequest else { return }
        session.toolRequest = nil
        guard connection.isConfigured, !anySheetShown, !appIsPresentingModalUI() else { return }
        switch request {
        case .reload:
            if !list.loading { list.reload() }
        case .spendingReport:
            showSpendingReport = true
        case .exportOrders:
            exportOrders()
        case .trackingForYourShop:
            showTracking = true
        }
    }

    private func exportOrders() {
        guard list.canUseRowsForTools, !list.orders.isEmpty else { return }
        exportError = dapiExportOrders(list.orders)
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
        guard let request = session.composerRequest else { return }
        // Without a key the request is dropped, so a composer never pops up later unasked.
        guard connection.isConfigured else { session.composerRequest = nil; return }
        guard composer == nil, cancelRequest == nil, !showSpendingReport, !showTracking else { return }
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
            DapiOrdersToolsMenu(hasOrders: list.hasRowsForTools,
                                showSpendingReport: $showSpendingReport, showTracking: $showTracking,
                                onExport: { exportOrders() })
                .disabled(!connection.isConfigured)
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
                    Text("\(dapiOrderListUnits(order))").monospacedDigit()
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
                    let reference = dapiOrderSellerReference(order.reference)
                    Text(reference ?? "—").foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        .help(reference ?? "")
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
            if let text = dapiOrdersEmptyText(status: list.status, search: list.appliedSearch) {
                let actions = dapiOrdersEmptyActions(status: list.status, search: list.appliedSearch)
                ContentUnavailableView {
                    Label(text.title, systemImage: list.appliedSearch.isEmpty ? "shippingbox" : "magnifyingglass")
                } description: {
                    Text(text.detail)
                } actions: {
                    if actions.contains(.clearSearch) {
                        Button("Clear Search") { searchText = ""; list.applySearch("") }
                    }
                    if actions.contains(.showAll) {
                        Button("Show All Orders") { searchText = ""; list.showAll() }
                    }
                }
            } else {
                // A typed search alone.
                ContentUnavailableView.search(text: list.appliedSearch)
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
                refreshError: list.refreshingOrderID == order.id ? nil : list.orderRefreshError(for: order.id),
                cancelUnknown: session.cancelOutcomeUnknown.contains(order.id),
                modelNames: nameIndex.names,
                onRefresh: { list.refreshOrder(id: order.id) },
                onDuplicate: { composer = DapiComposerSeed(duplicateOf: order) },
                duplicateBlockedReason: newOrderBlockedReason,
                onCancel: {
                    cancelRequest = DapiCancelRequest(orderID: order.id, number: order.number, shownStatus: order.status,
                                                      mode: order.mode)
                })
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
                if let note = dapiCancelUnavailableNote(order, cancelUnknown: cancelUnknown) {
                    Text(note).font(.callout).foregroundStyle(.secondary)
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
                if let reference = dapiOrderSellerReference(order.reference) {
                    GridRow {
                        Text("Reference").foregroundStyle(.secondary)
                        Text(reference).textSelection(.enabled)
                    }
                }
                // The full reference as 3DAPI holds it (with Plinth's code): 3DAPI support may ask for it.
                if let full = dapiNonEmpty(order.reference) {
                    GridRow {
                        Text("3DAPI reference").foregroundStyle(.secondary)
                        HStack(spacing: 8) {
                            Text(full).foregroundStyle(.secondary).textSelection(.enabled)
                            Button("Copy") { copyToPasteboard(full) }
                                .controlSize(.small)
                                .help("Copy the reference exactly as 3DAPI holds it")
                        }
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
            Button("Copy Order Number") { copyToPasteboard(order.number) }
            if dapiOffersProblemReport(status: order.status) {
                DapiReportProblemButton(order: order)
            }
            Spacer()
            // Last, and only while 3DAPI still lets the order be cancelled. It opens the cancel review only.
            if canOfferCancel {
                Button("Cancel Order…", role: .destructive) { onCancel() }
                    .help("Review cancelling this order. " + dapiCancelExplanation(mode: order.mode, status: order.status))
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
                Text("Your key doesn’t include orders:read_customer, so 3DAPI hides the customer and address.")
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
    /// Told when a lookup starts and ends (the composer keeps Review Order… off meanwhile).
    var onLookingChange: ((Bool) -> Void)? = nil
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
            .onChange(of: looking) { _, value in onLookingChange?(value) }
            .onDisappear {
                task?.cancel()
                task = nil
                if looking { looking = false }
                onLookingChange?(false)
            }
        }
    }

    private func lookFor(_ attempts: [DapiUnconfirmedOrder]) {
        guard !looking else { return }
        let connection = DapiConnection.shared
        let client: any DapiOrdering
        do { client = try connection.currentOrderingClient() } catch {
            summary = dapiFailureMessage(error)
            return
        }
        // Counted as a 3DAPI request, so the key can't change mid-lookup; results for an earlier key are dropped.
        let generation = connection.keyGeneration
        connection.beginRequest()
        looking = true
        summary = nil
        task = Task {
            // Found attempts are confirmed together once every read is done, right after `onFound`: a composer whose
            // own attempt was found closes then, without cutting the lookup of the others short.
            var found: [String] = []
            let results = await dapiLookForOrders(attempts, client: client,
                                                  pause: { try await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000)) },
                                                  confirm: { found.append($0) })
            connection.endRequest()
            looking = false
            task = nil
            guard generation == connection.keyGeneration else {
                // The key changed meanwhile (its Keychain item went): nothing found with it is applied.
                summary = nil
                return
            }
            let ordered = attempts.compactMap { results[$0.id] }
            for case .found(let order) in ordered.reversed() { onFound(order) }
            for reference in found { DapiOrderSession.shared.confirmUnconfirmedOrder(reference: reference) }
            summary = dapiOrderLookupSummary(ordered)
        }
    }
}
