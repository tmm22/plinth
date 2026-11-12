import SwiftUI

// MARK: - Tracking for Your Shop › Send Tracking to Shopify…
//
// Sends Slant's tracking for imported Shopify orders back to the store with `fulfillmentCreate`, marking as fulfilled
// only the items the Slant draft was made from (`metadata.sourceItems`, ShopifyOrderMatching.swift). It is a write to
// the seller's live store, and Shopify gives it no idempotency key, so: an explicit review and confirmation; the sheet
// is tied to the store it opened with; a draft from another store (`metadata.sourceShop`) is never sent, and one
// imported without its store must match the Shopify order's recipient and postcode first; each order is read again
// just before its send (already fulfilled or already carrying the tracking means it isn't sent); one send at a time,
// never retried; and the run stops at the first outcome Shopify didn't confirm. Customers are emailed only when the
// seller turns that on (the choice is remembered; it starts off).

/// Most orders one review lists.
let shopifyTrackingMaxOrders = 50
/// Pause between orders, so a run stays well inside Shopify's throttle.
let shopifyTrackingSpacing: TimeInterval = 0.5
/// Definite refusals in a row after which the run stops.
let shopifyTrackingMaxConsecutiveRefusals = 3
/// The seller's last "Email customers" choice. A preference only: no order or customer detail.
let shopifyTrackingNotifyCustomerKey = "shopifyTrackingNotifyCustomer"
/// Fulfillment order line items read per fulfillment order. More means the order can't be matched safely.
let shopifyFulfilmentLineItemsRead = 30
/// Fulfillment orders read per order. More means the order can't be matched safely.
let shopifyFulfilmentOrdersRead = 5

/// One order the review offers to send.
struct ShopifyTrackingCandidate: Identifiable, Equatable {
    /// The Slant order ID.
    let id: String
    /// The Shopify order name ("#1001"), as Import Orders recorded it.
    let orderName: String
    let trackingNumbers: [String]
    /// The carrier as Shopify names it, or empty (Shopify then works it out from the number).
    let company: String
    /// Whether `company` was worked out from the tracking numbers (`shopifyTrackingCompanyChoice`), not named by Slant.
    var companyFromNumber = false
    /// The store the draft was fetched from, or nil when it was imported from a CSV export.
    var sourceShop: String? = nil
    /// The Shopify items (and units) the draft was made from, or nil when they weren't recorded.
    var sourceItems: [ShopifySourceItem]? = nil
    /// For the same-order check when `sourceShop` is nil. Memory only.
    var recipientName = ""
    var postcode = ""
}

/// The send confirmation's message, naming the carriers that go with the tracking.
func shopifyTrackingConfirmationMessage(jobs: [ShopifyTrackingCandidate], notifyCustomer: Bool) -> String {
    var parts = ["Shopify marks the items Slant made in each order as fulfilled with this tracking, which Plinth can’t undo."]
    let carriers = shopifyTrackingCompanySentence(jobs)
    if !carriers.isEmpty { parts.append(carriers) }
    parts.append(notifyCustomer ? "Customers are emailed their shipping details." : "Customers aren’t emailed.")
    parts.append("Plinth sends one order at a time and stops if Shopify doesn’t confirm one.")
    return parts.joined(separator: " ")
}

/// The sheet's store and orders, fixed when it opens.
struct ShopifyTrackingSession: Identifiable {
    let id = UUID()
    let shop: String
    let candidates: [ShopifyTrackingCandidate]
}

/// Imported Shopify orders with Slant tracking, not marked done in the shop, at most 50. A cancelled Slant order (Slant's
/// own status, any spelling) is never offered, even if it still carries tracking: Slant cancels its fulfilment too.
func shopifyTrackingCandidates(_ entries: [ShopFollowUpEntry], done: Set<String>) -> [ShopifyTrackingCandidate] {
    var seen = Set<String>()
    return entries.compactMap { entry -> ShopifyTrackingCandidate? in
        guard entry.isShopify, !done.contains(entry.id), !orderStatusIsCancelled(entry.status), let id = entry.marketplaceID,
              !entry.trackingNumbers.isEmpty else { return nil }
        let name = shopifyOrderName(id)
        guard !name.isEmpty, seen.insert(entry.id).inserted else { return nil }
        let choice = shopifyTrackingCompanyChoice(entry)
        return ShopifyTrackingCandidate(id: entry.id, orderName: name, trackingNumbers: entry.trackingNumbers,
                                        company: shopifyTrackingCompanyName(choice.company),
                                        companyFromNumber: choice.fromNumber && !choice.company.isEmpty,
                                        sourceShop: entry.sourceShop, sourceItems: entry.sourceItems,
                                        recipientName: entry.recipientName, postcode: entry.postcode)
    }
    .prefix(shopifyTrackingMaxOrders).map { $0 }
}

/// Spelling fixes only: the same carrier under the exact name Shopify's 2026-10 tracking-company list uses (it matches
/// names exactly, capitals included, and builds tracking links only for names it knows; checked 12 Nov 2026). A name
/// that could mean more than one of Shopify's carriers (a bare "DHL": DHL Express, DHL eCommerce or, in Germany, DHL) is
/// never mapped to one of them; it and anything else not listed are sent as Slant wrote them.
private let shopifyCarrierNames: [String: String] = [
    "USPS": "USPS", "UPS": "UPS", "FEDEX": "FedEx", "DHLEXPRESS": "DHL Express",
    "DHLECOMMERCE": "DHL eCommerce", "ROYALMAIL": "Royal Mail", "AUSTRALIAPOST": "Australia Post",
    "CANADAPOST": "Canada Post", "EVRI": "Evri", "DPD": "DPD", "DPDUK": "DPD UK", "NEWZEALANDPOST": "New Zealand Post",
    "ONTRAC": "OnTrac", "PUROLATOR": "Purolator", "LASERSHIP": "Lasership",
    "GLS": "GLS", "POSTNL": "PostNL", "DEUTSCHEPOST": "Deutsche Post", "SENDLE": "Sendle"
]

/// The review's words for a candidate's company: just the carrier ("USPS", "UPS"), or nil when blank. Whether it was
/// worked out from the tracking numbers goes in the row's help (`shopifyTrackingCompanyHelp`).
func shopifyTrackingCompanyText(_ candidate: ShopifyTrackingCandidate) -> String? {
    candidate.company.isEmpty ? nil : candidate.company
}

/// Help for the row's carrier.
func shopifyTrackingCompanyHelp(_ candidate: ShopifyTrackingCandidate) -> String {
    candidate.companyFromNumber ? carrierDetectedHelp() : "The carrier Slant named."
}

/// The confirmation's sentence about the carriers sent: "Carrier sent: USPS for 2 orders; Shopify works out the
/// rest." (the last part only when some orders send none). Empty when no order names one.
func shopifyTrackingCompanySentence(_ jobs: [ShopifyTrackingCandidate]) -> String {
    var counts: [String: Int] = [:]
    for job in jobs where !job.company.isEmpty { counts[job.company, default: 0] += 1 }
    guard !counts.isEmpty else { return "" }
    let parts = counts.keys.sorted().map { name -> String in
        let count = counts[name] ?? 0
        return count == 1 ? "\(name) for 1 order" : "\(name) for \(count) orders"
    }
    let blank = jobs.count - counts.values.reduce(0, +)
    return "Carrier sent: \(parts.joined(separator: ", "))" + (blank > 0 ? "; Shopify works out the rest." : ".")
}

func shopifyTrackingCompanyName(_ provider: String) -> String {
    let trimmed = provider.trimmingCharacters(in: .whitespacesAndNewlines)
    let key = trimmed.uppercased().filter { $0.isLetter || $0.isNumber }
    return shopifyCarrierNames[key] ?? trimmed
}

/// Search syntax finding an order by its exact name, or nil for a name that can't be searched safely.
func shopifyOrderNameSearch(_ name: String) -> String? {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, trimmed.count <= 100, !trimmed.contains("\""), !trimmed.contains("\\"),
          !trimmed.contains(where: \.isNewline) else { return nil }
    return "name:\"\(trimmed)\""
}

let shopifyFindOrderQuery = "query StudioFindOrder($query: String!) { orders(first: 5, query: $query) { nodes { id name } } }"

/// The GID of the order whose name is exactly `name`; Shopify's name search may also return near matches.
func shopifyOrderID(named name: String, in data: [String: Any]) -> String? {
    let nodes = ((data["orders"] as? [String: Any])?["nodes"] as? [[String: Any]]) ?? []
    let wanted = name.trimmingCharacters(in: .whitespacesAndNewlines)
    let matches = nodes.filter { ($0["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) == wanted }
    guard matches.count == 1, let id = matches[0]["id"] as? String, id.hasPrefix("gid://shopify/Order/") else { return nil }
    return id
}

/// The order read before a send. The shipping name and postcode (protected customer data) are asked for only for an
/// order imported without its store, which needs the same-order check. Only the fulfillment orders Shopify shows the
/// merchant (`displayable`: those closed after being combined or moved are left out; they can't be fulfilled anyway).
func shopifyFulfilmentCheckQuery(includeAddress: Bool) -> String {
    """
    query StudioFulfilmentCheck($id: ID!) {
      order(id: $id) {
        name cancelledAt displayFulfillmentStatus\(includeAddress ? "\n    shippingAddress { name zip }" : "")
        fulfillments(first: 10) { trackingInfo(first: 5) { number } }
        fulfillmentOrders(first: \(shopifyFulfilmentOrdersRead), displayable: true) {
          pageInfo { hasNextPage }
          nodes {
            id status
            supportedActions { action }
            lineItems(first: \(shopifyFulfilmentLineItemsRead)) {
              pageInfo { hasNextPage }
              nodes { id remainingQuantity lineItem { id sku name } }
            }
          }
        }
      }
    }
    """
}

/// What a ready order's send would do.
struct ShopifyFulfilmentPlan: Equatable {
    let fulfillmentOrderID: String
    /// The fulfillment order line items and units sent.
    let lines: [ShopifyFulfilmentLine]
    /// What is marked as fulfilled ("2 × Mug").
    let items: [String]
    /// What stays unfulfilled in Shopify (items this draft doesn't hold).
    let remaining: [String]
    /// The order was imported without its store and matched on its recipient and postcode: tickable, never ticked
    /// for the seller.
    let matchedByAddress: Bool
}

/// What a read of the order says about sending its tracking.
enum ShopifyFulfilmentCheck: Equatable {
    case ready(ShopifyFulfilmentPlan)
    case alreadyHasTracking
    case alreadyFulfilled
    case cancelled
    case notFound
    /// Shopify splits the order into several fulfillment orders and not exactly one holds every unit of the draft.
    case severalShipments
    /// The draft was fetched from another store.
    case otherShop(String)
    case unavailable(String)

    var isReady: Bool { if case .ready = self { return true } else { return false } }

    var plan: ShopifyFulfilmentPlan? { if case .ready(let plan) = self { return plan } else { return nil } }

    var summary: String {
        switch self {
        case .ready(let plan):
            var text = plan.items.isEmpty ? "Ready to send." : "Marks as fulfilled: \(plan.items.joined(separator: ", "))."
            if !plan.remaining.isEmpty { text += " Stays unfulfilled: \(plan.remaining.joined(separator: ", "))." }
            if plan.matchedByAddress {
                text += " Imported from a CSV file, so matched on its recipient and postcode: tick it if this is the right order."
            }
            return text
        case .alreadyHasTracking: return "Shopify already has this tracking number. Not sent."
        case .alreadyFulfilled: return "Shopify shows this order as fulfilled. Not sent."
        case .cancelled: return "Shopify shows this order as cancelled. Not sent."
        case .notFound: return "No Shopify order has this exact name, or it’s more than 60 days old, which Plinth can’t read. Not sent."
        case .severalShipments: return "Shopify splits this order into several shipments, so Plinth can’t tell which one Slant’s parcel is. Add its tracking in Shopify."
        case .otherShop(let shop): return "Imported from \(shop), not the connected store. Not sent."
        case .unavailable(let reason): return reason
        }
    }
}

let shopifyItemsNotRecordedReason = "Plinth didn’t record which of this order’s items the Slant draft holds, so it can’t mark only those as fulfilled. Add its tracking in Shopify."

/// The same-order check's inputs for an order imported without its store; nil skips the check (the draft names the
/// connected store).
struct ShopifyIdentityExpectation: Equatable {
    let recipientName: String
    let postcode: String
}

func shopifyFulfilmentCheck(_ data: [String: Any], trackingNumbers: [String], sourceItems: [ShopifySourceItem]?,
                            identity: ShopifyIdentityExpectation?) -> ShopifyFulfilmentCheck {
    guard let order = data["order"] as? [String: Any] else { return .notFound }
    if let cancelled = order["cancelledAt"] as? String, !cancelled.isEmpty { return .cancelled }
    let ours = Set(trackingNumbers.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() })
    let fulfillments = (order["fulfillments"] as? [[String: Any]]) ?? []
    let existing = fulfillments.flatMap { ($0["trackingInfo"] as? [[String: Any]]) ?? [] }
        .compactMap { ($0["number"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() }
    if existing.contains(where: ours.contains) { return .alreadyHasTracking }
    if let identity {
        let address = order["shippingAddress"] as? [String: Any]
        if let problem = shopifyIdentityProblem(shopifyName: (address?["name"] as? String) ?? "", shopifyPostcode: (address?["zip"] as? String) ?? "",
                                                slantName: identity.recipientName, slantPostcode: identity.postcode) {
            return .unavailable(problem)
        }
    }
    let connection = order["fulfillmentOrders"] as? [String: Any]
    if ((connection?["pageInfo"] as? [String: Any])?["hasNextPage"] as? Bool) == true {
        return .unavailable("This order has more fulfilment orders in Shopify than Plinth reads. Add its tracking in Shopify.")
    }
    let fulfillable = ((connection?["nodes"] as? [[String: Any]]) ?? []).filter { node in
        let actions = (node["supportedActions"] as? [[String: Any]]) ?? []
        return actions.contains { ($0["action"] as? String) == "CREATE_FULFILLMENT" }
    }
    guard !fulfillable.isEmpty else {
        switch order["displayFulfillmentStatus"] as? String {
        case "FULFILLED": return .alreadyFulfilled
        case "FULFILLMENT_NOT_REQUIRED": return .unavailable("Shopify shows nothing left to fulfil in this order (removed or refunded). Not sent.")
        default: return .unavailable("Shopify has nothing to fulfil for this order here (it may be on hold, scheduled or with a fulfilment service). Not sent.")
        }
    }
    var read: [ShopifyFulfilmentOrderRead] = []
    for node in fulfillable {
        switch shopifyFulfilmentOrderRead(node) {
        case .failure(let error): return .unavailable(error.message)
        case .success(let fulfilmentOrder): read.append(fulfilmentOrder)
        }
    }
    guard let sourceItems, !sourceItems.isEmpty else { return .unavailable(shopifyItemsNotRecordedReason) }
    let allocations = read.map { shopifyAllocateFulfilment(sourceItems, lines: $0.lines) }
    if allocations.count == 1, case .failure(let error) = allocations[0] { return .unavailable(error.message) }
    // Each fulfillment order that could take every unit of the draft on its own. Sent only when exactly one can: two
    // that could, or the units spread over several, leave Plinth unable to tell which shipment is Slant's parcel.
    let fits = zip(read, allocations).compactMap { fulfilmentOrder, allocation -> (ShopifyFulfilmentOrderRead, [ShopifyFulfilmentLine])? in
        guard case .success(let chosen) = allocation else { return nil }
        return (fulfilmentOrder, chosen)
    }
    guard fits.count == 1, let fit = fits.first else { return .severalShipments }
    let (chosenOrder, chosen) = fit
    let taken = Dictionary(chosen.map { ($0.id, $0.quantity) }, uniquingKeysWith: +)
    let names = read.reduce(into: [String: String]()) { $0.merge($1.names) { first, _ in first } }
    let items = chosen.map { "\($0.quantity) × \(names[$0.id] ?? "Item")" }
    // What stays unfulfilled in every fulfillment order read, not only the one sent.
    let remaining = read.flatMap(\.lines).compactMap { line -> String? in
        let left = line.remaining - (taken[line.id] ?? 0)
        return left > 0 ? "\(left) × \(names[line.id] ?? "Item")" : nil
    }
    return .ready(ShopifyFulfilmentPlan(fulfillmentOrderID: chosenOrder.id, lines: chosen, items: items, remaining: remaining,
                                        matchedByAddress: identity != nil))
}

/// One fulfillment order as the check reads it.
struct ShopifyFulfilmentOrderRead: Equatable {
    let id: String
    let lines: [ShopifyFulfilmentOrderLine]
    /// Each line's item name for the review ("Item" when Shopify gave none).
    let names: [String: String]
}

/// A fulfillment order node read strictly: its ID, and every line with its remaining units, or why it can't be used.
func shopifyFulfilmentOrderRead(_ node: [String: Any]) -> Result<ShopifyFulfilmentOrderRead, StudioError> {
    guard let id = node["id"] as? String, id.hasPrefix("gid://shopify/FulfillmentOrder/") else {
        return .failure(StudioError("Shopify’s reply couldn’t be read. Not sent."))
    }
    let lineItems = node["lineItems"] as? [String: Any]
    if ((lineItems?["pageInfo"] as? [String: Any])?["hasNextPage"] as? Bool) == true {
        return .failure(StudioError("This order has more than \(shopifyFulfilmentLineItemsRead) items in Shopify. Add its tracking in Shopify."))
    }
    var lines: [ShopifyFulfilmentOrderLine] = []
    var names: [String: String] = [:]
    for line in (lineItems?["nodes"] as? [[String: Any]]) ?? [] {
        guard let lineID = line["id"] as? String, lineID.hasPrefix("gid://shopify/FulfillmentOrderLineItem/"),
              let remaining = (line["remainingQuantity"] as? NSNumber)?.intValue else {
            return .failure(StudioError("Shopify’s reply couldn’t be read. Not sent."))
        }
        let item = line["lineItem"] as? [String: Any]
        let name = ((item?["name"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        names[lineID] = name.isEmpty ? "Item" : name
        lines.append(ShopifyFulfilmentOrderLine(
            id: lineID, remaining: remaining, lineItemID: shopifyNumericID((item?["id"] as? String) ?? "", type: "LineItem"),
            sku: (item?["sku"] as? String) ?? "", name: name))
    }
    return .success(ShopifyFulfilmentOrderRead(id: id, lines: lines, names: names))
}

let shopifyFulfillmentCreateMutation = """
mutation StudioSendTracking($fulfillment: FulfillmentInput!) {
  fulfillmentCreate(fulfillment: $fulfillment) {
    fulfillment { id status }
    userErrors { field message }
  }
}
"""

/// The `FulfillmentInput`: exactly the plan's line items and units of one fulfillment order, with the tracking
/// number(s) and company. No URL: Shopify builds tracking links for the carriers it knows.
func shopifyFulfillmentInput(_ plan: ShopifyFulfilmentPlan, trackingNumbers: [String], company: String, notifyCustomer: Bool) -> [String: Any] {
    let numbers = trackingNumbers.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    var tracking: [String: Any] = [:]
    if numbers.count == 1 { tracking["number"] = numbers[0] } else if !numbers.isEmpty { tracking["numbers"] = numbers }
    let company = company.trimmingCharacters(in: .whitespacesAndNewlines)
    if !company.isEmpty { tracking["company"] = company }
    let lineItems: [[String: Any]] = plan.lines.map { ["id": $0.id, "quantity": $0.quantity] }
    var input: [String: Any] = [
        "lineItemsByFulfillmentOrder": [["fulfillmentOrderId": plan.fulfillmentOrderID, "fulfillmentOrderLineItems": lineItems]],
        "notifyCustomer": notifyCustomer
    ]
    if !tracking.isEmpty { input["trackingInfo"] = tracking }
    return input
}

enum ShopifyTrackingOutcome: Equatable {
    case sent
    /// Shopify definitely didn't fulfil the order.
    case refused(String)
    /// Shopify may have fulfilled it.
    case unknown(String)
}

func shopifyTrackingOutcome(response data: [String: Any]) -> ShopifyTrackingOutcome {
    guard let result = data["fulfillmentCreate"] as? [String: Any] else {
        return .unknown("Shopify’s reply didn’t say whether the order was fulfilled.")
    }
    let errors = (result["userErrors"] as? [[String: Any]]) ?? []
    if !errors.isEmpty {
        let message = errors.compactMap { $0["message"] as? String }.first ?? "Shopify refused it."
        return .refused(shopifyRedacted(message))
    }
    guard let fulfillment = result["fulfillment"] as? [String: Any], fulfillment["id"] is String else {
        return .unknown("Shopify’s reply didn’t confirm a fulfilment.")
    }
    return .sent
}

func shopifyTrackingOutcome(error: Error) -> ShopifyTrackingOutcome {
    let message = shopifyRedacted(error.localizedDescription)
    return shopifyMutationOutcomeUnknown(error) ? .unknown(message) : .refused(message)
}

/// Activity's line for a run: counts only. `checkFailed`: the run stopped because an order couldn't be read again.
func shopifyTrackingActivityDetail(sent: Int, refused: Int, unknown: Int, skipped: Int, checkFailed: Bool = false) -> String {
    var parts = [sent == 1 ? "1 sent" : "\(sent) sent"]
    if refused > 0 { parts.append("\(refused) refused") }
    if unknown > 0 { parts.append("\(unknown) not confirmed") }
    if skipped > 0 { parts.append("\(skipped) not needed") }
    if checkFailed { parts.append("stopped: Shopify couldn’t be read") }
    return parts.joined(separator: ", ")
}

/// Whether Activity records the run as a success: nothing refused, unconfirmed or left unchecked.
func shopifyTrackingRunSucceeded(refused: Int, unknown: Int, checkFailed: Bool) -> Bool {
    refused == 0 && unknown == 0 && !checkFailed
}

/// Whether a send run stops before its next request to Shopify: Stop was pressed or the sheet closed, the task was
/// cancelled, the connected store isn't the sheet's, a send wasn't confirmed, or Shopify refused too many in a row.
/// Checked before each order and again just before its `fulfillmentCreate`, so it can only ever skip a send.
func shopifyTrackingShouldStop(stopRequested: Bool, cancelled: Bool, shopMatches: Bool, unknown: Int, refusedInRow: Int) -> Bool {
    stopRequested || cancelled || !shopMatches || unknown > 0 || refusedInRow >= shopifyTrackingMaxConsecutiveRefusals
}

/// Ticked for the seller after a check: ready, matched by its store (not by address), and no unconfirmed earlier send.
func shopifyTrackingTickedByDefault(_ check: ShopifyFulfilmentCheck, hasUnconfirmedSend: Bool) -> Bool {
    guard let plan = check.plan else { return false }
    return !plan.matchedByAddress && !hasUnconfirmedSend
}

// MARK: Runner

enum ShopifyTrackingRowState: Equatable {
    case checking
    case checked(ShopifyFulfilmentCheck)
    case checkFailed(String)
    case sending
    case sent
    case refused(String)
    case unknown(String)
    case notSent
}

@MainActor final class ShopifyTrackingRunner: ObservableObject {
    @Published private(set) var states: [String: ShopifyTrackingRowState] = [:]
    @Published private(set) var checking = false
    @Published private(set) var sending = false
    @Published private(set) var message: String?
    @Published private(set) var canFulfil: Bool?
    private var stopRequested = false

    var running: Bool { checking || sending }

    func requestStop() { stopRequested = true }

    /// The sheet's store changed in Settings: stop before the next request and say why.
    func connectionChanged() {
        stopRequested = true
        message = ShopifyError.shopChanged.errorDescription
    }

    /// The client for `shop`, or `shopChanged` when the connected store is no longer the one the sheet opened with.
    private func client(for shop: String) throws -> ShopifyClient {
        let connection = ShopifyConnection.shared
        guard connection.shop == shop else { throw ShopifyError.shopChanged }
        let client = try connection.currentClient()
        guard client.shop == shop else { throw ShopifyError.shopChanged }
        return client
    }

    /// Read-only: finds each order and what sending would do.
    func check(_ candidates: [ShopifyTrackingCandidate], shop: String) async {
        guard !running, !candidates.isEmpty else { return }
        let connection = ShopifyConnection.shared
        guard !connection.busy else {
            // Nothing was read, so no row is left saying "Checking…"; Check Again works once the other task ends.
            message = "Wait for the other Shopify task to finish, then Check Again."
            for candidate in candidates { states[candidate.id] = .notSent }
            return
        }
        stopRequested = false
        checking = true
        connection.busy = true
        defer { checking = false; connection.busy = false }
        message = nil
        do {
            let shopClient = try client(for: shop)
            // Scopes remembered without a fulfilment scope are read again (and a Dev Dashboard app's token renewed),
            // so adding the scope as the sheet says takes effect on Check Again, without quitting.
            if shopifyScopesNeedReread(shopClient.grantedScopes) { shopClient.forgetScopes() }
            canFulfil = shopifyScopeSummary(try await shopClient.accessScopes()).canFulfil
        } catch {
            message = shopifyRedacted(error.localizedDescription)
            for candidate in candidates { states[candidate.id] = .notSent }
            return
        }
        // Without a fulfilment scope Shopify can't show fulfilment orders either; the sheet explains the scope.
        guard canFulfil == true else {
            for candidate in candidates { states[candidate.id] = .notSent }
            return
        }
        for candidate in candidates { states[candidate.id] = .checking }
        var failed = false
        for candidate in candidates {
            if stopRequested || Task.isCancelled || failed { states[candidate.id] = .notSent; continue }
            do {
                states[candidate.id] = .checked(try await fulfilmentCheck(candidate, shop: shop))
            } catch {
                // One failed read (access, throttle, connection) would fail for the rest too; stop asking.
                states[candidate.id] = .checkFailed(shopifyRedacted(error.localizedDescription))
                failed = true
                if case ShopifyError.shopChanged? = error as? ShopifyError {
                    message = ShopifyError.shopChanged.errorDescription
                } else {
                    message = "Stopped checking after Shopify couldn’t be read. Check Again tries the rest."
                }
            }
        }
    }

    /// Sends one at a time: each order is read again first, and the run stops at the first unconfirmed outcome.
    /// Returns false when the run couldn't start (another Shopify task, or the store changed), so nothing was read
    /// or sent.
    @discardableResult
    func send(_ candidates: [ShopifyTrackingCandidate], shop: String, notifyCustomer: Bool, store: StudioStore) async -> Bool {
        guard !running, !candidates.isEmpty else { return false }
        let connection = ShopifyConnection.shared
        guard !connection.busy else { message = "Wait for the other Shopify task to finish."; return false }
        guard connection.shop == shop else { message = ShopifyError.shopChanged.errorDescription; return false }
        stopRequested = false
        sending = true
        connection.busy = true
        defer { sending = false; connection.busy = false }
        message = nil
        var sent = 0, refused = 0, unknown = 0, skipped = 0, refusedInRow = 0
        var shopChanged = false
        var checkFailed = false
        func shouldStop() -> Bool {
            if connection.shop != shop { shopChanged = true }
            return shopifyTrackingShouldStop(stopRequested: stopRequested, cancelled: Task.isCancelled, shopMatches: !shopChanged,
                                             unknown: unknown, refusedInRow: refusedInRow)
        }
        for (index, candidate) in candidates.enumerated() {
            // The pause comes first, so a Stop pressed during it still takes effect before the next order.
            if index > 0 { try? await Task.sleep(nanoseconds: UInt64(shopifyTrackingSpacing * 1_000_000_000)) }
            if shouldStop() {
                for rest in candidates[index...] { states[rest.id] = .notSent }
                break
            }
            states[candidate.id] = .sending
            let check: ShopifyFulfilmentCheck
            do {
                check = try await fulfilmentCheck(candidate, shop: shop)
            } catch {
                // Nothing was sent for this order; a failed read still ends the run.
                if case ShopifyError.shopChanged? = error as? ShopifyError { shopChanged = true } else { checkFailed = true }
                states[candidate.id] = .checkFailed(shopifyRedacted(error.localizedDescription))
                for rest in candidates.dropFirst(index + 1) { states[rest.id] = .notSent }
                break
            }
            guard case .ready(let plan) = check else {
                states[candidate.id] = .checked(check)
                skipped += 1
                continue
            }
            // The re-check's two reads may each wait out Shopify's throttle, so Stop, closing the sheet or a store
            // change may have come meanwhile: honoured here, before the write, and once more inside `mutate`, after its
            // own wait and token fetch. Either way nothing is sent for this order or the rest.
            if shouldStop() {
                for rest in candidates[index...] { states[rest.id] = .notSent }
                break
            }
            var stoppedBeforeSending = false
            let outcome: ShopifyTrackingOutcome
            do {
                // Checked again right before the write: the store must still be the one the sheet opened with.
                let shopClient = try client(for: shop)
                let input = shopifyFulfillmentInput(plan, trackingNumbers: candidate.trackingNumbers,
                                                    company: candidate.company, notifyCustomer: notifyCustomer)
                let reply = try await shopClient.mutate(shopifyFulfillmentCreateMutation, variables: ["fulfillment": input]) {
                    stoppedBeforeSending = shouldStop()
                    return !stoppedBeforeSending
                }
                outcome = shopifyTrackingOutcome(response: reply)
            } catch {
                if case ShopifyError.shopChanged? = error as? ShopifyError { shopChanged = true }
                if stoppedBeforeSending {
                    // `mutate` stopped before sending (`.notSent`): not a refusal, just not sent.
                    for rest in candidates[index...] { states[rest.id] = .notSent }
                    break
                }
                outcome = shopifyTrackingOutcome(error: error)
            }
            switch outcome {
            case .sent:
                sent += 1
                refusedInRow = 0
                states[candidate.id] = .sent
                connection.unconfirmedTrackingSends[candidate.id] = nil
                store.shopFollowUpDoneIDs.insert(candidate.id)
            case .refused(let reason):
                refused += 1
                refusedInRow += 1
                states[candidate.id] = .refused(reason)
            case .unknown(let reason):
                unknown += 1
                states[candidate.id] = .unknown(reason)
                connection.unconfirmedTrackingSends[candidate.id] = Date()
            }
        }
        if unknown > 0 {
            message = "Stopped: Shopify didn’t confirm one send. Check that order in Shopify before sending it again; Plinth checks it again first."
        } else if shopChanged {
            message = ShopifyError.shopChanged.errorDescription
        } else if checkFailed {
            message = "Stopped: Shopify couldn’t be read. Orders not sent are unchanged in Shopify; Check Again tries the rest."
        } else if refusedInRow >= shopifyTrackingMaxConsecutiveRefusals {
            message = "Stopped after \(shopifyTrackingMaxConsecutiveRefusals) refusals in a row."
        } else if stopRequested {
            message = "Stopped. Orders not sent are unchanged in Shopify."
        }
        store.activities.insert(Activity(title: "Send tracking to Shopify",
                                         detail: shopifyTrackingActivityDetail(sent: sent, refused: refused, unknown: unknown,
                                                                               skipped: skipped, checkFailed: checkFailed),
                                         success: shopifyTrackingRunSucceeded(refused: refused, unknown: unknown, checkFailed: checkFailed)), at: 0)
        return true
    }

    private func fulfilmentCheck(_ candidate: ShopifyTrackingCandidate, shop: String) async throws -> ShopifyFulfilmentCheck {
        // A draft fetched from another store is never looked up, let alone sent.
        if let source = candidate.sourceShop, source != shop { return .otherShop(source) }
        // Without the draft's items nothing could be sent, so Shopify isn't asked (nor for the address).
        guard let items = candidate.sourceItems, !items.isEmpty else { return .unavailable(shopifyItemsNotRecordedReason) }
        guard let search = shopifyOrderNameSearch(candidate.orderName) else {
            return .unavailable("This order name can’t be looked up in Shopify. Add its tracking in Shopify.")
        }
        let found = try await client(for: shop).query(shopifyFindOrderQuery, variables: ["query": search], estimatedCost: 10)
        guard let id = shopifyOrderID(named: candidate.orderName, in: found) else { return .notFound }
        let identity = candidate.sourceShop == nil
            ? ShopifyIdentityExpectation(recipientName: candidate.recipientName, postcode: candidate.postcode) : nil
        let detail: [String: Any]
        do {
            detail = try await client(for: shop).query(shopifyFulfilmentCheckQuery(includeAddress: identity != nil),
                                                            variables: ["id": id], estimatedCost: 250)
        } catch ShopifyError.protectedCustomerData where identity != nil {
            // Only this order needs the address; the others can still be checked.
            return .unavailable("Shopify didn’t share this order’s address with the app you connected, so Plinth can’t confirm it’s the order this draft was imported from. Add its tracking in Shopify.")
        }
        return shopifyFulfilmentCheck(detail, trackingNumbers: candidate.trackingNumbers, sourceItems: items, identity: identity)
    }
}

// MARK: Sheet

struct ShopifyTrackingSheet: View {
    @EnvironmentObject var store: StudioStore
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var connection = ShopifyConnection.shared
    @StateObject private var runner = ShopifyTrackingRunner()
    /// The store the sheet opened with. Nothing is checked or sent once the connection names another.
    let shop: String
    /// Fixed when the sheet opens, so the list doesn't change under the review.
    let candidates: [ShopifyTrackingCandidate]
    @State private var ticked: Set<String> = []
    /// The seller's last choice, remembered; off the first time.
    @AppStorage(shopifyTrackingNotifyCustomerKey) private var notifyCustomer = false
    @State private var confirmSend = false
    @State private var task: Task<Void, Never>?
    @State private var registered = false

    private var shopMatches: Bool { connection.shop == shop }

    private var readyIDs: [String] {
        candidates.map(\.id).filter { id in
            guard ticked.contains(id), case .checked(let check)? = runner.states[id] else { return false }
            return check.isReady
        }
    }

    var body: some View {
        let count = readyIDs.count
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Send tracking to Shopify").font(.title2.weight(.bold))
                Text("Adds Slant’s tracking to each Shopify order in \(shop) and marks the items Slant made as fulfilled; anything else in the order stays unfulfilled. Plinth checks each order first and skips any that Shopify already shows as fulfilled or with this tracking.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            List(candidates) { row($0) }
                .listStyle(.inset(alternatesRowBackgrounds: false))
                .frame(minHeight: 220)
            Toggle("Email customers their shipping details", isOn: $notifyCustomer)
                .disabled(runner.running)
                .help("Shopify sends its shipping confirmation email to each customer whose order is sent. Plinth remembers this choice.")
            if !shopMatches {
                Label("The Shopify connection changed in Settings. Close this and open it again to send to the connected store.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.studioWarning).fixedSize(horizontal: false, vertical: true)
            }
            if runner.canFulfil == false {
                Label("The app can’t fulfil orders yet. Add the write_merchant_managed_fulfillment_orders scope in the Dev Dashboard, release a new version and approve it on the store (for an older custom app, add it to the app’s Admin API scopes in the store admin), then Check Again.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.studioWarning).fixedSize(horizontal: false, vertical: true)
            }
            if let message = runner.message {
                Text(message).font(.callout).fixedSize(horizontal: false, vertical: true)
            }
            // Sheet footers: this sheet sends to Shopify, so Close sits at the leading edge, apart from Send Tracking.
            HStack {
                Button(runner.running ? "Close and Stop" : "Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                if runner.running {
                    ProgressView().controlSize(.small)
                    Text(runner.checking ? "Checking orders in Shopify…" : "Sending…").font(.callout)
                    Button("Stop") { runner.requestStop() }
                        .help("Stops before the next request to Shopify. A send already on its way finishes first.")
                }
                Spacer()
                if !runner.running, candidates.contains(where: { runner.states[$0.id] != .sent }) {
                    Button("Check Again") { recheck() }
                        .disabled(connection.busy || !shopMatches)
                        .help("Read these orders from Shopify again. Nothing is sent.")
                }
                // No default-action shortcut: sending always takes a click and the confirmation.
                Button(count == 1 ? "Send Tracking for 1 Order…" : "Send Tracking for \(count) Orders…") { confirmSend = true }
                    .buttonStyle(.borderedProminent)
                    .disabled(count == 0 || runner.running || connection.busy || runner.canFulfil == false || !shopMatches)
            }
        }
        .padding(20)
        .frame(minWidth: 640, idealWidth: 720, minHeight: 440, idealHeight: 540)
        .confirmationDialog(count == 1 ? "Send tracking for 1 Shopify order?" : "Send tracking for \(count) Shopify orders?",
                            isPresented: $confirmSend, titleVisibility: .visible) {
            Button("Send Tracking") { startSend() }
            // Return cancels, so pressing it twice can't start a run.
            Button("Cancel", role: .cancel) {}
                .keyboardShortcut(.defaultAction)
        } message: {
            Text(shopifyTrackingConfirmationMessage(jobs: candidates.filter { readyIDs.contains($0.id) }, notifyCustomer: notifyCustomer))
        }
        .onAppear {
            if !registered { registered = true; connection.trackingSheetOpened() }
            guard task == nil else { return }
            recheck()
        }
        .onChange(of: connection.shop) { _, newShop in
            guard newShop != shop else { return }
            confirmSend = false
            ticked = []
            runner.connectionChanged()
        }
        .onDisappear {
            // Closing stops the run before its next request to Shopify; a send already on its way finishes.
            runner.requestStop()
            if registered { registered = false; connection.trackingSheetClosed() }
        }
    }

    private func row(_ candidate: ShopifyTrackingCandidate) -> some View {
        let state = runner.states[candidate.id]
        let ready: Bool = { if case .checked(let check)? = state { return check.isReady } else { return false } }()
        return HStack(alignment: .top, spacing: 10) {
            Toggle("Send tracking for \(candidate.orderName)", isOn: Binding(
                get: { ticked.contains(candidate.id) && ready },
                set: { if $0 { ticked.insert(candidate.id) } else { ticked.remove(candidate.id) } }))
                .labelsHidden()
                .toggleStyle(.checkbox)
                .accessibilityLabel("Send tracking for Shopify order \(candidate.orderName)")
                .disabled(!ready || runner.running || !shopMatches)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text("Shopify order \(candidate.orderName)").fontWeight(.semibold).lineLimit(1)
                    if let company = shopifyTrackingCompanyText(candidate) {
                        Text("· \(company)").foregroundStyle(.secondary).lineLimit(1)
                            .help(shopifyTrackingCompanyHelp(candidate))
                    }
                }
                Text(candidate.trackingNumbers.joined(separator: ", ")).font(.callout.monospaced()).lineLimit(2).textSelection(.enabled)
                if connection.unconfirmedTrackingSends[candidate.id] != nil, state != .sent {
                    Label("An earlier send this session wasn’t confirmed. Check the order in Shopify before ticking it.", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.studioWarning)
                }
                stateLabel(state)
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func stateLabel(_ state: ShopifyTrackingRowState?) -> some View {
        switch state {
        case nil, .checking?:
            Label("Checking…", systemImage: "clock").font(.caption).foregroundStyle(.secondary)
        case .checked(let check)?:
            Label(check.summary, systemImage: check.isReady ? "checkmark.circle" : "minus.circle")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        case .checkFailed(let reason)?:
            Label("Couldn’t check: \(reason)", systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.studioWarning)
        case .sending?:
            Label("Sending…", systemImage: "arrow.up.circle").font(.caption).foregroundStyle(.secondary)
        case .sent?:
            Label("Sent. Marked as done in your shop.", systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(.studioSuccess)
        case .refused(let reason)?:
            Label("Not sent: \(reason)", systemImage: "xmark.circle.fill").font(.caption).foregroundStyle(.studioError)
        case .unknown(let reason)?:
            Label("Not confirmed: \(reason)", systemImage: "questionmark.circle.fill").font(.caption).foregroundStyle(.studioWarning)
        case .notSent?:
            Label("Not sent", systemImage: "minus.circle").font(.caption).foregroundStyle(.secondary)
        }
    }

    /// Reads every order not yet sent. Ready orders are ticked, except one matched only by its recipient and postcode
    /// and one whose earlier send this session wasn't confirmed.
    private func recheck() {
        guard !runner.running, shopMatches else { return }
        let pending = candidates.filter { runner.states[$0.id] != .sent }
        guard !pending.isEmpty else { return }
        task = Task { @MainActor in
            await runner.check(pending, shop: shop)
            guard connection.shop == shop else { ticked = []; return }
            ticked = Set(pending.map(\.id).filter { id in
                guard case .checked(let check)? = runner.states[id] else { return false }
                return shopifyTrackingTickedByDefault(check, hasUnconfirmedSend: connection.unconfirmedTrackingSends[id] != nil)
            })
        }
    }

    private func startSend() {
        guard !runner.running, !connection.busy, shopMatches else { return }
        let ids = Set(readyIDs)
        let jobs = candidates.filter { ids.contains($0.id) }
        guard !jobs.isEmpty else { return }
        task = Task { @MainActor in
            // Rows in a run are unticked once it ends, so pressing Send again never resends them without a fresh check
            // and tick. A run that couldn't start (another Shopify task) keeps the seller's ticks.
            if await runner.send(jobs, shop: shop, notifyCustomer: notifyCustomer, store: store) { ticked.subtract(ids) }
        }
    }
}
