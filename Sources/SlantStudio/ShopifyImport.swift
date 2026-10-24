import SwiftUI

// MARK: - Import Orders › From Shopify…
//
// Fetches the store's paid, unfulfilled orders (read-only, bounded, throttle-aware) and turns them into the same
// `OrderImportParse` a Shopify CSV export gives, so the Import Orders sheet's checks, Match products, confirmation and
// paced draft runner apply unchanged. `sourceOrderID` is the order's name ("#1001"), as the CSV's Name column, so the
// session ledger and the loaded-orders metadata check catch an order imported either way. Like the CSV path, the
// names, emails and addresses stay in the sheet's memory: never on disk, in preferences, logs or Activity.

let shopifyImportMaxOrders = 250
let shopifyImportDays = 60
/// Orders per page. With 30 line items each, a page's requested cost stays near half of Shopify's 1,000-point cap.
let shopifyImportPageSize = 8
let shopifyImportLineItemsPerOrder = 30
/// The estimated cost of one page, for waiting out the throttle before asking.
let shopifyImportPageCost: Double = 520

/// Shopify search syntax for the import: paid, unfulfilled, open orders created on or after `since` (UTC day). The
/// `read_orders` scope only reaches the last 60 days anyway.
func shopifyImportSearchQuery(now: Date = Date(), days: Int = shopifyImportDays) -> String {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
    let since = calendar.date(byAdding: .day, value: -days, to: now) ?? now
    let parts = calendar.dateComponents([.year, .month, .day], from: since)
    let day = String(format: "%04d-%02d-%02d", parts.year ?? 1970, parts.month ?? 1, parts.day ?? 1)
    return "financial_status:paid fulfillment_status:unfulfilled status:open created_at:>=\(day)"
}

let shopifyImportOrdersQuery = """
query StudioImportOrders($first: Int!, $after: String, $query: String!) {
  orders(first: $first, after: $after, query: $query, sortKey: CREATED_AT) {
    pageInfo { hasNextPage endCursor }
    nodes {
      name email createdAt cancelledAt displayFinancialStatus displayFulfillmentStatus
      shippingAddress { name firstName lastName company address1 address2 city province provinceCode zip countryCodeV2 }
      lineItems(first: \(shopifyImportLineItemsPerOrder)) {
        pageInfo { hasNextPage }
        nodes { name sku quantity currentQuantity customAttributes { key value } }
      }
    }
  }
}
"""

func shopifyImportVariables(after cursor: String?, searchQuery: String) -> [String: Any] {
    var variables: [String: Any] = ["first": shopifyImportPageSize, "query": searchQuery]
    if let cursor { variables["after"] = cursor }
    return variables
}

/// One page of the `orders` connection.
struct ShopifyOrdersPage {
    var nodes: [[String: Any]]
    var hasNextPage: Bool
    var endCursor: String?
}

func shopifyOrdersPage(_ data: [String: Any]) throws -> ShopifyOrdersPage {
    guard let orders = data["orders"] as? [String: Any], let nodes = orders["nodes"] as? [[String: Any]] else {
        throw ShopifyError.invalidResponse("Shopify’s order list couldn’t be read.")
    }
    let info = orders["pageInfo"] as? [String: Any]
    let cursor = (info?["endCursor"] as? String).flatMap { $0.isEmpty ? nil : $0 }
    return ShopifyOrdersPage(nodes: nodes, hasNextPage: (info?["hasNextPage"] as? Bool) ?? false, endCursor: cursor)
}

/// The cursor for the next page, or nil to stop: no further page, a missing cursor, a cursor already used (which
/// would loop), or enough orders fetched.
func shopifyNextCursor(_ page: ShopifyOrdersPage, used: Set<String>, fetched: Int, limit: Int = shopifyImportMaxOrders) -> String? {
    guard page.hasNextPage, fetched < limit, let cursor = page.endCursor, !used.contains(cursor) else { return nil }
    return cursor
}

private func shopifyText(_ value: Any?) -> String {
    guard let text = value as? String else { return "" }
    return text.trimmingCharacters(in: .whitespacesAndNewlines)
}

/// A line item's visible properties ("Engraving: Emma"), as Shopify shows them on the order. Properties whose key
/// starts with an underscore are hidden by Shopify and left out.
func shopifyLineItemOptions(_ attributes: Any?) -> String {
    guard let list = attributes as? [[String: Any]] else { return "" }
    return list.compactMap { attribute -> String? in
        let key = shopifyText(attribute["key"]), value = shopifyText(attribute["value"])
        guard !key.isEmpty, !key.hasPrefix("_"), !value.isEmpty else { return nil }
        return "\(key): \(value)"
    }.joined(separator: ", ")
}

/// The buyer's personalisation for display: a "Personalisation" property's value, else every visible property.
/// Shopify personalisation apps name their properties freely, so any property counts: such orders start unticked,
/// because drafts use the saved product's model unchanged.
func shopifyLineItemPersonalisation(options: String) -> String {
    guard !options.isEmpty else { return "" }
    let named = orderImportPersonalisation(options: options, column: "")
    return named.isEmpty ? options : named
}

/// One order as Import Orders sees it, or the reason it was left out. `nextRow` numbers its items (the sheet's
/// "item on row N" label for an item with neither SKU nor name).
func shopifyImportOrder(_ node: [String: Any], nextRow: inout Int) -> (order: OrderImportOrder?, leftOut: String?) {
    let name = shopifyText(node["name"])
    guard !name.isEmpty else { return (nil, "An order without a name was left out.") }
    if let lineItems = node["lineItems"] as? [String: Any], let info = lineItems["pageInfo"] as? [String: Any],
       (info["hasNextPage"] as? Bool) == true {
        return (nil, "Order \(name) has more than \(shopifyImportLineItemsPerOrder) items, so it was left out. Import it from a CSV export.")
    }
    var order = OrderImportOrder(source: .shopify, sourceOrderID: name)
    order.email = shopifyText(node["email"])
    if let address = node["shippingAddress"] as? [String: Any] {
        var recipient = shopifyText(address["name"])
        if recipient.isEmpty {
            recipient = [shopifyText(address["firstName"]), shopifyText(address["lastName"])].filter { !$0.isEmpty }.joined(separator: " ")
        }
        order.name = recipient
        order.company = shopifyText(address["company"])
        order.line1 = shopifyText(address["address1"])
        order.line2 = shopifyText(address["address2"])
        order.city = shopifyText(address["city"])
        let provinceCode = shopifyText(address["provinceCode"])
        order.state = provinceCode.isEmpty ? shopifyText(address["province"]) : provinceCode
        order.zip = shopifyText(address["zip"])
        order.country = shopifyText(address["countryCodeV2"])
        order.countryCode = orderImportCountryCode(order.country)
    }
    let nodes = ((node["lineItems"] as? [String: Any])?["nodes"] as? [[String: Any]]) ?? []
    for item in nodes {
        // `currentQuantity` leaves out units removed or refunded since the order was placed.
        let quantity = (item["currentQuantity"] as? NSNumber) ?? (item["quantity"] as? NSNumber)
        guard let units = quantity?.intValue, units > 0 else { continue }
        let row = nextRow
        nextRow += 1
        order.rows.append(row)
        var entry = OrderImportItem(sku: shopifyText(item["sku"]), quantityText: String(units), itemName: shopifyText(item["name"]), row: row)
        entry.options = shopifyLineItemOptions(item["customAttributes"])
        entry.personalisation = shopifyLineItemPersonalisation(options: entry.options)
        order.items.append(entry)
    }
    order.alreadyHandled = orderImportAlreadyHandledReason(
        format: .shopify, dateShipped: "", fulfillmentStatus: shopifyText(node["displayFulfillmentStatus"]),
        cancelledAt: shopifyText(node["cancelledAt"]), financialStatus: shopifyText(node["displayFinancialStatus"]))
    return (order, nil)
}

/// The fetched orders as an import parse, oldest first as fetched. An order name seen twice (the list shifting while
/// pages are read) is kept once.
func shopifyImportParse(_ nodes: [[String: Any]], shop: String, truncated: Bool) throws -> OrderImportParse {
    var orders: [OrderImportOrder] = []
    var seen = Set<String>()
    var notices: [String] = []
    var nextRow = 1
    for node in nodes {
        let result = shopifyImportOrder(node, nextRow: &nextRow)
        if let reason = result.leftOut { notices.append(reason) }
        guard let order = result.order, seen.insert(order.sourceOrderID).inserted else { continue }
        orders.append(order)
    }
    guard !orders.isEmpty else {
        throw StudioError("Shopify has no paid, unfulfilled orders from the last \(shopifyImportDays) days for \(shop).")
    }
    notices.insert("Fetched from \(shop): paid, unfulfilled orders from the last \(shopifyImportDays) days, oldest first.", at: 0)
    if truncated {
        notices.append("Shopify has more matching orders than the \(shopifyImportMaxOrders) Studio fetches at once. Import these, or use a CSV export for the rest.")
    }
    return OrderImportParse(format: .shopify, orders: orders, notices: notices)
}

extension ShopifyConnection {
    /// Fetches up to 250 paid, unfulfilled orders, a page at a time. Read-only. Stops at the first failure, so a
    /// partial list is never shown as complete.
    func fetchImportOrders(progress: @escaping (Int) -> Void) async throws -> OrderImportParse {
        let client = try currentClient()
        busy = true
        defer { busy = false }
        let search = shopifyImportSearchQuery()
        var nodes: [[String: Any]] = []
        var cursor: String?
        var used = Set<String>()
        var truncated = false
        repeat {
            try Task.checkCancellation()
            let data = try await client.query(shopifyImportOrdersQuery, variables: shopifyImportVariables(after: cursor, searchQuery: search),
                                              estimatedCost: shopifyImportPageCost)
            let page = try shopifyOrdersPage(data)
            let room = shopifyImportMaxOrders - nodes.count
            if page.nodes.count > room { truncated = true }
            nodes.append(contentsOf: page.nodes.prefix(room))
            progress(nodes.count)
            if let current = cursor { used.insert(current) }
            let next = shopifyNextCursor(page, used: used, fetched: nodes.count)
            if next == nil, page.hasNextPage {
                // A full list is cut short on purpose; any other stop would show a partial list as complete.
                guard nodes.count >= shopifyImportMaxOrders else {
                    throw ShopifyError.invalidResponse("Shopify’s order list didn’t continue as expected. Try again.")
                }
                truncated = true
            }
            cursor = next
        } while cursor != nil
        return try shopifyImportParse(nodes, shop: client.shop, truncated: truncated)
    }
}

// MARK: - The sheet's button

/// "From Shopify…" beside Choose File…, shown once Shopify is connected in Settings. Fetching is read-only and can
/// be stopped; closing the sheet stops it too, and nothing fetched is kept.
struct ShopifyImportFetchButton: View {
    @EnvironmentObject var store: StudioStore
    @ObservedObject private var connection = ShopifyConnection.shared
    let disabled: Bool
    let onLoaded: (OrderImportParse, String) -> Void
    let onError: (String) -> Void
    @State private var task: Task<Void, Never>?
    @State private var fetched = 0

    var body: some View {
        Group { content }
            .onDisappear { stop() }
    }

    @ViewBuilder
    private var content: some View {
        if connection.isConfigured {
            if task != nil {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(fetched == 0 ? "Fetching from Shopify…" : "Fetching from Shopify… \(fetched) orders").font(.callout)
                    Button("Stop") { stop() }
                }
            } else {
                Button("From Shopify…") { fetch() }
                    .disabled(disabled || connection.busy)
                    .help("Fetch paid, unfulfilled orders from \(connection.shop ?? "your store") (last \(shopifyImportDays) days, up to \(shopifyImportMaxOrders)). Nothing is sent to Slant until you confirm.")
            }
        }
    }

    private func fetch() {
        guard task == nil, !disabled, !connection.busy, let shop = connection.shop else { return }
        fetched = 0
        task = Task { @MainActor in
            // A stopped fetch has already cleared `task`, which may by now hold a newer fetch.
            defer { if !Task.isCancelled { task = nil } }
            do {
                let parse = try await connection.fetchImportOrders { count in fetched = count }
                guard !Task.isCancelled else { return }
                onLoaded(parse, "Shopify · \(shop)")
                store.activities.insert(Activity(title: "Fetch Shopify orders",
                                                 detail: parse.orders.count == 1 ? "1 order" : "\(parse.orders.count) orders",
                                                 success: true), at: 0)
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                let message = shopifyRedacted(error.localizedDescription)
                onError(message)
                store.activities.insert(Activity(title: "Fetch Shopify orders", detail: "Not fetched", success: false), at: 0)
            }
        }
    }

    private func stop() {
        task?.cancel()
        task = nil
    }
}
