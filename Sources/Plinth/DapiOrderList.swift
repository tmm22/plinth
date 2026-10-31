import Combine
import Foundation

// The 3DAPI Orders list's state: pages read newest first by cursor, the Status filter and server-side search, the
// selection, and the session bookkeeping each read settles (`dapiSessionSettlements`). Reads only, never retried
// automatically, and cancelled when the Orders screen goes away. Memory only: orders (with any customer details 3DAPI
// returned) are never saved.

/// Longest search 3DAPI accepts.
let dapiOrderSearchMaxLength = 100
/// Orders per page.
let dapiOrderPageSize = 50

/// The query for one page: the status filter (one status, or every status), the search (part of the number or
/// reference, trimmed and cut to 100 characters, none when empty) and the cursor for Load More.
func dapiOrderListQuery(status: DapiOrderStatus?, search: String, cursor: String?) -> DapiOrderListQuery {
    let trimmed = String(search.trimmingCharacters(in: .whitespacesAndNewlines).prefix(dapiOrderSearchMaxLength))
    return DapiOrderListQuery(statuses: status.map { [$0] } ?? [], search: trimmed.isEmpty ? nil : trimmed,
                              cursor: cursor, limit: dapiOrderPageSize, expandItems: true)
}

/// `incoming` as the newer copy of `existing`, keeping `existing`'s lines when `incoming` came without them (a cancel
/// reply, or a list page read without `expand[]=items`).
func dapiOrderKeepingItems(_ incoming: DapiOrder, from existing: DapiOrder) -> DapiOrder {
    guard incoming.items == nil, let items = existing.items, incoming.id == existing.id else { return incoming }
    return DapiOrder(id: incoming.id, number: incoming.number, status: incoming.status, mode: incoming.mode,
                     reference: incoming.reference, customerName: incoming.customerName,
                     customerEmail: incoming.customerEmail, formattedAddress: incoming.formattedAddress,
                     city: incoming.city, countryName: incoming.countryName, countryCode: incoming.countryCode,
                     charges: incoming.charges, shipping: incoming.shipping, itemCount: incoming.itemCount, items: items,
                     refunds: incoming.refunds, createdAt: incoming.createdAt, updatedAt: incoming.updatedAt)
}

/// The loaded orders with a new page merged in: an order already listed is replaced where it stands (with its newer
/// copy, keeping its lines when the newer copy has none), and new ones are appended in the page's order. Never two
/// rows with one ID.
func dapiMergeOrders(_ existing: [DapiOrder], with incoming: [DapiOrder]) -> [DapiOrder] {
    var result = existing
    var index: [String: Int] = [:]
    for (position, order) in result.enumerated() where index[order.id] == nil { index[order.id] = position }
    for order in incoming {
        if let position = index[order.id] {
            result[position] = dapiOrderKeepingItems(order, from: result[position])
        } else {
            index[order.id] = result.count
            result.append(order)
        }
    }
    return result
}

/// A placed or found order, first in the list (any older copy removed, its lines kept when the new copy has none).
func dapiInsertingOrder(_ order: DapiOrder, into orders: [DapiOrder]) -> [DapiOrder] {
    let merged = orders.first(where: { $0.id == order.id }).map { dapiOrderKeepingItems(order, from: $0) } ?? order
    return [merged] + orders.filter { $0.id != order.id }
}

/// A re-read order in place of its older copy (keeping its lines when the new copy has none); first in the list when
/// it wasn't listed.
func dapiReplacingOrder(_ order: DapiOrder, in orders: [DapiOrder]) -> [DapiOrder] {
    guard let position = orders.firstIndex(where: { $0.id == order.id }) else { return [order] + orders }
    var result = orders
    result[position] = dapiOrderKeepingItems(order, from: orders[position])
    return result
}

/// The empty list's title and explanation, naming the filter or search that emptied it. Nil for a typed search alone
/// (`ContentUnavailableView.search` covers it); a search with a status filter names both (`dapiOrdersEmptyActions`
/// offers both ways back).
func dapiOrdersEmptyText(status: DapiOrderStatus?, search: String) -> (title: String, detail: String)? {
    let trimmed = search.trimmingCharacters(in: .whitespacesAndNewlines)
    if !trimmed.isEmpty {
        guard let status else { return nil }
        return ("No “\(status.label)” orders match “\(trimmed)”",
                "3DAPI has no orders with the status “\(status.label)” whose number or reference contains “\(trimmed)”.")
    }
    if let status {
        return ("No “\(status.label)” orders", "3DAPI has no orders with the status “\(status.label)”.")
    }
    return ("No 3DAPI orders yet", "Orders you place on 3DAPI appear here.")
}

/// The filter a set of rows was read with.
struct DapiOrderListFilter: Equatable {
    var status: DapiOrderStatus?
    var search: String
}

/// Whether an order belongs under a filter: its status, when one is chosen, and the search as part of its number or
/// reference in any case (3DAPI's own search). Used for orders shown on their own (a notification, a placed or found
/// order), which no page read with the filter listed.
func dapiOrderMatchesFilter(_ order: DapiOrder, _ filter: DapiOrderListFilter) -> Bool {
    if let status = filter.status, order.status != status { return false }
    let search = filter.search.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !search.isEmpty else { return true }
    return [order.number, order.reference ?? ""].contains { $0.range(of: search, options: .caseInsensitive) != nil }
}

/// Orders shown on their own this session that the list keeps.
let dapiPinnedOrderLimit = 10

/// A fresh first page's rows, with the orders shown on their own (`pinned`, newest first) that the page doesn't list
/// and that match the filter, first. So an order a notification or a placed order put in the list isn't dropped by a
/// page read before or after it, and a row that doesn't match the filter shown is never added.
func dapiRowsKeepingPinned(_ rows: [DapiOrder], pinned: [DapiOrder], filter: DapiOrderListFilter) -> [DapiOrder] {
    let listed = Set(rows.map(\.id))
    let kept = pinned.filter { !listed.contains($0.id) && dapiOrderMatchesFilter($0, filter) }
    return dapiMergeOrders(kept, with: rows)
}

/// The orders one Activity line can name: never numbers, references, prices or names.
let dapiOrdersActivityTitle = "3DAPI orders"

/// What the list talks to; tests pass stubs.
struct DapiOrderListEnvironment {
    var client: @MainActor () throws -> any DapiOrdering
    var unconfirmedOrders: @MainActor () -> [DapiUnconfirmedOrder]
    var cancelOutcomeUnknown: @MainActor () -> Set<String>
    var confirmUnconfirmed: @MainActor (String) -> Void
    var clearCancelUnknown: @MainActor (String) -> Void
    /// The status each unknown-outcome cancel was sent from (`DapiCancelSession`), for `dapiCancelLockLifted`.
    var cancelSentFrom: @MainActor () -> [String: DapiOrderStatus] = { [:] }

    @MainActor static func live() -> DapiOrderListEnvironment {
        DapiOrderListEnvironment(
            client: { try DapiConnection.shared.currentOrderingClient() },
            unconfirmedOrders: { DapiOrderSession.shared.unconfirmedOrders },
            cancelOutcomeUnknown: { DapiOrderSession.shared.cancelOutcomeUnknown },
            confirmUnconfirmed: { DapiOrderSession.shared.confirmUnconfirmedOrder(reference: $0) },
            clearCancelUnknown: { DapiCancelSession.shared.clear(orderID: $0) },
            cancelSentFrom: { DapiCancelSession.shared.sentFrom })
    }
}

@MainActor final class DapiOrderListState: ObservableObject {
    /// The Orders screen's list. It outlives the screen (the orders loaded stay for the next visit) and forgets every
    /// order as soon as the key is saved, replaced or removed, even while Orders isn't shown; the screen reads again
    /// when it next appears (`keyChanged`).
    static let shared: DapiOrderListState = {
        let list = DapiOrderListState(environment: .live())
        // @Published sends the new value before the property changes, so only the value passed in is used.
        list.keySubscription = DapiConnection.shared.$keyGeneration.dropFirst().sink { [weak list] generation in
            MainActor.assumeIsolated { list?.forgetIfKeyChanged(generation: generation) }
        }
        return list
    }()

    @Published private(set) var orders: [DapiOrder] = []
    @Published private(set) var hasMore = false
    @Published private(set) var loading = false
    @Published private(set) var loaded = false
    /// The last read's failure (redacted), shown inline.
    @Published private(set) var loadError: String?
    /// The status filter (applied at once; nil shows every status).
    @Published private(set) var status: DapiOrderStatus?
    /// The search applied to the loaded pages.
    @Published private(set) var appliedSearch = ""
    @Published var selection: String?
    /// The order being read on its own (Refresh this order, or a notification click).
    @Published private(set) var refreshingOrderID: String?
    /// The last single-order read's failure, and the order it was for: shown only with that order.
    @Published private(set) var orderRefreshFailure: (orderID: String, message: String)?
    /// The `DapiConnection.keyGeneration` these orders were read with (`keyChanged`).
    private(set) var keyGeneration: Int?

    private var nextCursor: String?
    private var loadTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    /// Bumped by every reset, so a page for an earlier filter (or key) is dropped.
    private var generation = 0
    /// Bumped only when the key's orders are forgotten, so a single-order read for an earlier key is dropped.
    private var accountGeneration = 0
    /// Each single-order read's own token, so its spinner always clears when that read ends.
    private var refreshToken: UUID?
    /// The filter the listed rows were read with; nil before the first page.
    private var rowsFilter: DapiOrderListFilter?
    /// Orders shown on their own (`show`, `insertAndSelect`), newest first, as last read: a fresh first page keeps them
    /// (`dapiRowsKeepingPinned`). Forgotten with the key's orders.
    private(set) var pinned: [DapiOrder] = []
    /// The latest page read's task, kept after it ends or is stopped, so tests can wait for it.
    private(set) var lastLoadTask: Task<Void, Never>?
    private var keySubscription: AnyCancellable?
    private let environment: DapiOrderListEnvironment
    var log: ((_ title: String, _ detail: String, _ success: Bool) -> Void)?

    init(environment: DapiOrderListEnvironment) {
        self.environment = environment
    }

    var selectedOrder: DapiOrder? { orders.first { $0.id == selection } }

    /// Rows the tools (Export Orders, Tracking for Your Shop, and the File menu's versions) can use now.
    var hasRowsForTools: Bool { canUseRowsForTools && !orders.isEmpty }

    /// The filter shown now.
    var shownFilter: DapiOrderListFilter { DapiOrderListFilter(status: status, search: appliedSearch) }

    /// Whether the rows are the shown filter's (the tools — Export Orders, Spending Report, Tracking for Your Shop —
    /// use them only then). A filter change clears the rows at once, so this holds except before the first page.
    var canUseRowsForTools: Bool { rowsFilter == nil ? orders.isEmpty : rowsFilter == shownFilter }

    /// The failure of the last single-order read of `orderID`, if that read was for it.
    func orderRefreshError(for orderID: String) -> String? {
        guard let failure = orderRefreshFailure, failure.orderID == orderID else { return nil }
        return failure.message
    }

    /// Reads page 1 again with the current filter and search.
    func reload() {
        startLoad(reset: true)
    }

    func loadMore() {
        guard hasMore, nextCursor != nil, !loading else { return }
        startLoad(reset: false)
    }

    func applyStatus(_ status: DapiOrderStatus?) {
        guard status != self.status else { return }
        self.status = status
        startLoad(reset: true)
    }

    func applySearch(_ search: String) {
        let trimmed = String(search.trimmingCharacters(in: .whitespacesAndNewlines).prefix(dapiOrderSearchMaxLength))
        guard trimmed != appliedSearch else { return }
        appliedSearch = trimmed
        startLoad(reset: true)
    }

    /// Shows every order again (the empty state's Show All Orders).
    func showAll() {
        status = nil
        appliedSearch = ""
        startLoad(reset: true)
    }

    /// The key or account changed: forget every order of the earlier one. Replies still on their way are dropped.
    func forgetAll() {
        cancel()
        generation += 1
        accountGeneration += 1
        orders = []
        hasMore = false
        nextCursor = nil
        rowsFilter = nil
        loaded = false
        loadError = nil
        selection = nil
        orderRefreshFailure = nil
        pinned = []
    }

    /// Forgets the earlier key's orders (and drops its replies) when `newGeneration` differs from the one these orders
    /// were read with; nothing otherwise. Returns whether it forgot.
    @discardableResult
    func forgetIfKeyChanged(generation newGeneration: Int) -> Bool {
        guard keyGeneration != newGeneration else { return false }
        keyGeneration = newGeneration
        forgetAll()
        return true
    }

    /// The Orders screen appeared, or `DapiConnection.keyGeneration` changed (a key saved, replaced or removed, even to
    /// a key that looks like the same account): a new generation forgets the earlier key's orders and drops its replies.
    /// Then, with a key saved, a list whose first page wasn't read yet (or whose read was stopped) is read; loaded
    /// orders, or a failed read (never retried by itself), stay as they are. The same generation again never forgets or
    /// reads loaded orders.
    func keyChanged(generation newGeneration: Int, configured: Bool) {
        forgetIfKeyChanged(generation: newGeneration)
        // An order shown on its own (`show`, `insertAndSelect`) isn't a page: the page is still read.
        if configured, rowsFilter == nil, loadError == nil, !loading { reload() }
    }

    /// Stops every read (the screen went away). Loaded orders stay.
    func cancel() {
        loadTask?.cancel()
        loadTask = nil
        refreshTask?.cancel()
        refreshTask = nil
        refreshToken = nil
        loading = false
        refreshingOrderID = nil
    }

    private func startLoad(reset: Bool) {
        loadTask?.cancel()
        let filter = shownFilter
        if reset {
            generation += 1
            if rowsFilter != nil, rowsFilter != filter {
                // Another filter: the earlier filter's rows (and their Load More) go at once, so the list never shows
                // rows that don't match the filter shown, even if this read fails or is stopped.
                orders = []
                hasMore = false
                nextCursor = nil
                rowsFilter = nil
                loaded = false
            } else if rowsFilter == nil {
                // No page yet: only orders shown on their own are listed; keep those the filter shown matches.
                orders = orders.filter { dapiOrderMatchesFilter($0, filter) }
            }
            // The same filter (Refresh): the rows and their cursor stay until the new page arrives, so a failed
            // read leaves a working Load More.
        }
        let current = generation
        let query = dapiOrderListQuery(status: status, search: appliedSearch, cursor: reset ? nil : nextCursor)
        loading = true
        loadError = nil
        let task = Task { [weak self] in
            guard let self else { return }
            let result: Result<DapiOrderPage, Error>
            do { result = .success(try await self.environment.client().orders(query)) } catch { result = .failure(error) }
            guard !Task.isCancelled, current == self.generation else { return }
            self.loading = false
            self.loadTask = nil
            switch result {
            case .success(let page):
                if reset {
                    // Orders shown on their own that this page doesn't list stay (a notification's order read before
                    // or after the page, a placed order 3DAPI doesn't list yet), when they match the filter.
                    self.refreshPinned(from: self.orders)
                    self.orders = dapiRowsKeepingPinned(dapiMergeOrders([], with: page.orders), pinned: self.pinned,
                                                        filter: filter)
                } else {
                    self.orders = dapiMergeOrders(self.orders, with: page.orders)
                }
                self.refreshPinned(from: page.orders)
                self.hasMore = page.hasMore && page.nextCursor != nil
                self.nextCursor = page.nextCursor
                self.rowsFilter = filter
                self.loaded = true
                self.settle(page.orders)
            case .failure(let error):
                if dapiIsCancellation(error) { return }
                if reset { self.loaded = true }
                self.loadError = dapiFailureMessage(error)
                self.log?(dapiOrdersActivityTitle, (error as? DapiError)?.activityDetail ?? "Read failed", false)
            }
        }
        loadTask = task
        lastLoadTask = task
    }

    /// Keeps the pinned orders' copies as fresh as `rows` (the newer copy, its lines kept when it has none).
    private func refreshPinned(from rows: [DapiOrder]) {
        guard !pinned.isEmpty else { return }
        pinned = pinned.map { pin in rows.first { $0.id == pin.id }.map { dapiOrderKeepingItems($0, from: pin) } ?? pin }
    }

    /// An order shown on its own: pinned (newest first, at most `dapiPinnedOrderLimit`), listed and selected. When it
    /// doesn't match the filter shown, every order is shown again (Status and search cleared, page 1 read again), so
    /// the list never holds a row that doesn't match the filter shown and the tools only see rows that do.
    private func showOnItsOwn(_ order: DapiOrder, first: Bool) {
        pinned = Array(([order] + pinned.filter { $0.id != order.id }).prefix(dapiPinnedOrderLimit))
        if !dapiOrderMatchesFilter(order, shownFilter) {
            status = nil
            appliedSearch = ""
            startLoad(reset: true)
        }
        orders = first ? dapiInsertingOrder(order, into: orders) : dapiReplacingOrder(order, in: orders)
        loaded = true
        selection = order.id
        settle([order])
    }

    /// Refresh this order: one read of the selected order, replacing its row.
    func refreshOrder(id: String) {
        readOrder(id: id, select: false)
    }

    /// A clicked order notification: one read of that order by ID, shown first in the list (when it isn't listed)
    /// and selected, and kept by later pages (`showOnItsOwn`, which clears a filter it doesn't match). Read-only.
    func show(orderID id: String) {
        if orders.contains(where: { $0.id == id }) { selection = id }
        readOrder(id: id, select: true)
    }

    private func readOrder(id: String, select: Bool) {
        refreshTask?.cancel()
        let account = accountGeneration
        let token = UUID()
        refreshToken = token
        refreshingOrderID = id
        if orderRefreshFailure?.orderID == id { orderRefreshFailure = nil }
        refreshTask = Task { [weak self] in
            guard let self else { return }
            let result: Result<DapiOrder, Error>
            do { result = .success(try await self.environment.client().order(id: id)) } catch { result = .failure(error) }
            // The spinner belongs to this read: it clears whenever this read ends, whatever else happened meanwhile.
            guard self.refreshToken == token else { return }
            self.refreshToken = nil
            self.refreshingOrderID = nil
            self.refreshTask = nil
            guard !Task.isCancelled, account == self.accountGeneration else { return }
            switch result {
            case .success(let order):
                guard order.id == id else { return }
                if select {
                    self.showOnItsOwn(order, first: false)
                } else if self.orders.contains(where: { $0.id == order.id }) {
                    self.apply(order)
                }
            case .failure(let error):
                if dapiIsCancellation(error) { return }
                self.orderRefreshFailure = (id, dapiFailureMessage(error))
                self.log?(dapiOrdersActivityTitle, (error as? DapiError)?.activityDetail ?? "Read failed", false)
            }
        }
    }

    /// A re-read or returned order (refresh, cancel, lookup) in place of its older copy.
    func apply(_ order: DapiOrder) {
        orders = dapiReplacingOrder(order, in: orders)
        refreshPinned(from: [order])
        settle([order])
    }

    /// A newly placed or found order: first in the list, and selected (clearing a filter it doesn't match).
    func insertAndSelect(_ order: DapiOrder) {
        showOnItsOwn(order, first: true)
    }

    private func settle(_ orders: [DapiOrder]) {
        let settled = dapiSessionSettlements(orders, unconfirmed: environment.unconfirmedOrders(),
                                             cancelUnknown: environment.cancelOutcomeUnknown(),
                                             cancelSentFrom: environment.cancelSentFrom())
        settled.confirmReferences.forEach { environment.confirmUnconfirmed($0) }
        settled.clearCancelIDs.forEach { environment.clearCancelUnknown($0) }
    }
}
