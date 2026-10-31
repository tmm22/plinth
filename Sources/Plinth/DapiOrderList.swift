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

/// The loaded orders with a new page merged in: an order already listed is replaced where it stands (with its newer
/// copy), and new ones are appended in the page's order. Never two rows with one ID.
func dapiMergeOrders(_ existing: [DapiOrder], with incoming: [DapiOrder]) -> [DapiOrder] {
    var result = existing
    var index: [String: Int] = [:]
    for (position, order) in result.enumerated() where index[order.id] == nil { index[order.id] = position }
    for order in incoming {
        if let position = index[order.id] {
            result[position] = order
        } else {
            index[order.id] = result.count
            result.append(order)
        }
    }
    return result
}

/// A placed or found order, first in the list (any older copy removed).
func dapiInsertingOrder(_ order: DapiOrder, into orders: [DapiOrder]) -> [DapiOrder] {
    [order] + orders.filter { $0.id != order.id }
}

/// A re-read order in place of its older copy; first in the list when it wasn't listed.
func dapiReplacingOrder(_ order: DapiOrder, in orders: [DapiOrder]) -> [DapiOrder] {
    guard let position = orders.firstIndex(where: { $0.id == order.id }) else { return [order] + orders }
    var result = orders
    result[position] = order
    return result
}

/// The empty list's title and explanation, naming the filter or search that emptied it.
func dapiOrdersEmptyText(status: DapiOrderStatus?, search: String) -> (title: String, detail: String)? {
    let trimmed = search.trimmingCharacters(in: .whitespacesAndNewlines)
    if !trimmed.isEmpty { return nil } // ContentUnavailableView.search covers a typed search.
    if let status {
        return ("No “\(status.label)” orders", "3DAPI has no orders with the status “\(status.label)”.")
    }
    return ("No 3DAPI orders yet", "Orders you place on 3DAPI appear here.")
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

    @MainActor static func live() -> DapiOrderListEnvironment {
        DapiOrderListEnvironment(
            client: { try DapiConnection.shared.currentOrderingClient() },
            unconfirmedOrders: { DapiOrderSession.shared.unconfirmedOrders },
            cancelOutcomeUnknown: { DapiOrderSession.shared.cancelOutcomeUnknown },
            confirmUnconfirmed: { DapiOrderSession.shared.confirmUnconfirmedOrder(reference: $0) },
            clearCancelUnknown: { DapiOrderSession.shared.clearCancelOutcomeUnknown(orderID: $0) })
    }
}

@MainActor final class DapiOrderListState: ObservableObject {
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
    /// The selected order's own read (Refresh this order).
    @Published private(set) var refreshingOrderID: String?
    @Published private(set) var orderRefreshError: String?

    private var nextCursor: String?
    private var loadTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    /// Bumped by every reset, so a reply for an earlier list (or key) is dropped.
    private var generation = 0
    private let environment: DapiOrderListEnvironment
    var log: ((_ title: String, _ detail: String, _ success: Bool) -> Void)?

    init(environment: DapiOrderListEnvironment) {
        self.environment = environment
    }

    var selectedOrder: DapiOrder? { orders.first { $0.id == selection } }

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

    /// The key or account changed: forget every order of the earlier one.
    func forgetAll() {
        cancel()
        generation += 1
        orders = []
        hasMore = false
        nextCursor = nil
        loaded = false
        loadError = nil
        selection = nil
        orderRefreshError = nil
    }

    /// Stops every read (the screen went away). Loaded orders stay.
    func cancel() {
        loadTask?.cancel()
        loadTask = nil
        refreshTask?.cancel()
        refreshTask = nil
        loading = false
        refreshingOrderID = nil
    }

    private func startLoad(reset: Bool) {
        loadTask?.cancel()
        if reset { generation += 1; nextCursor = nil }
        let current = generation
        let query = dapiOrderListQuery(status: status, search: appliedSearch, cursor: reset ? nil : nextCursor)
        loading = true
        loadError = nil
        loadTask = Task { [weak self] in
            guard let self else { return }
            let result: Result<DapiOrderPage, Error>
            do { result = .success(try await self.environment.client().orders(query)) } catch { result = .failure(error) }
            guard !Task.isCancelled, current == self.generation else { return }
            self.loading = false
            self.loadTask = nil
            switch result {
            case .success(let page):
                self.orders = reset ? dapiMergeOrders([], with: page.orders) : dapiMergeOrders(self.orders, with: page.orders)
                self.hasMore = page.hasMore && page.nextCursor != nil
                self.nextCursor = page.nextCursor
                self.loaded = true
                self.settle(page.orders)
            case .failure(let error):
                if dapiIsCancellation(error) { return }
                if reset { self.loaded = true }
                self.loadError = dapiFailureMessage(error)
                self.log?(dapiOrdersActivityTitle, (error as? DapiError)?.activityDetail ?? "Read failed", false)
            }
        }
    }

    /// Refresh this order: one read of the selected order.
    func refreshOrder(id: String) {
        refreshTask?.cancel()
        let current = generation
        refreshingOrderID = id
        orderRefreshError = nil
        refreshTask = Task { [weak self] in
            guard let self else { return }
            let result: Result<DapiOrder, Error>
            do { result = .success(try await self.environment.client().order(id: id)) } catch { result = .failure(error) }
            guard !Task.isCancelled, current == self.generation else { return }
            self.refreshingOrderID = nil
            self.refreshTask = nil
            switch result {
            case .success(let order): self.apply(order)
            case .failure(let error):
                if dapiIsCancellation(error) { return }
                self.orderRefreshError = dapiFailureMessage(error)
                self.log?(dapiOrdersActivityTitle, (error as? DapiError)?.activityDetail ?? "Read failed", false)
            }
        }
    }

    /// A re-read or returned order (refresh, cancel, lookup) in place of its older copy.
    func apply(_ order: DapiOrder) {
        orders = dapiReplacingOrder(order, in: orders)
        settle([order])
    }

    /// A newly placed or found order: first in the list, and selected.
    func insertAndSelect(_ order: DapiOrder) {
        orders = dapiInsertingOrder(order, into: orders)
        loaded = true
        selection = order.id
        settle([order])
    }

    private func settle(_ orders: [DapiOrder]) {
        let settled = dapiSessionSettlements(orders, unconfirmed: environment.unconfirmedOrders(),
                                             cancelUnknown: environment.cancelOutcomeUnknown())
        settled.confirmReferences.forEach { environment.confirmUnconfirmed($0) }
        settled.clearCancelIDs.forEach { environment.clearCancelUnknown($0) }
    }
}
