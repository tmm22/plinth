import Foundation

// 3DAPI ordering: the types shared by the client (DapiClient.swift), the Orders section for 3DAPI
// (DapiOrdersView.swift and friends), the derived read-only tools (DapiOrderInsights*.swift) and the order watch
// (DapiOrderWatch.swift). See docs/3DAPI_REFERENCE.md §7.
//
// 3DAPI has no draft orders: `POST /v2/integrator/orders` in wallet mode CHARGES AT ONCE and returns a paid order. So
// Plinth composes the order locally, reviews it (fresh quote, shipping estimate, account checks), and only an explicit
// Place Order sends it, once, with a fresh Idempotency-Key, never retried. Checkout mode (3DAPI as merchant of record)
// is not used. 3DAPI orders are never mapped into Slant's order records: several of 3DAPI's status words collide with
// Slant's older ones (PAID, COMPLETED) and would be treated as cancellable or late.

/// A 3DAPI order status (`OrderStatus`). Unknown words are kept as sent and are never cancellable, counted as spend,
/// late or placed.
enum DapiOrderStatus: Equatable, Hashable, Sendable {
    case awaitingPayment, paid, assigned, inProduction, shipped, completed, onHold, rejected, returned, cancelled
    case unknown(String)

    init(raw: String) {
        switch raw.trimmingCharacters(in: .whitespaces).lowercased() {
        case "awaiting_payment": self = .awaitingPayment
        case "paid": self = .paid
        case "assigned": self = .assigned
        case "in_production": self = .inProduction
        case "shipped": self = .shipped
        case "completed": self = .completed
        case "on_hold": self = .onHold
        case "rejected": self = .rejected
        case "returned": self = .returned
        case "cancelled": self = .cancelled
        default: self = .unknown(raw)
        }
    }

    /// The word 3DAPI uses (for queries and CSV).
    var raw: String {
        switch self {
        case .awaitingPayment: "awaiting_payment"
        case .paid: "paid"
        case .assigned: "assigned"
        case .inProduction: "in_production"
        case .shipped: "shipped"
        case .completed: "completed"
        case .onHold: "on_hold"
        case .rejected: "rejected"
        case .returned: "returned"
        case .cancelled: "cancelled"
        case .unknown(let word): word
        }
    }

    /// Every status 3DAPI documents, in lifecycle order (for the Status filter).
    static let known: [DapiOrderStatus] = [.awaitingPayment, .paid, .assigned, .inProduction, .shipped, .completed,
                                          .onHold, .rejected, .returned, .cancelled]

    /// Sentence-case label for lists and the detail.
    var label: String {
        switch self {
        case .awaitingPayment: "Awaiting payment"
        case .paid: "Paid"
        case .assigned: "Assigned"
        case .inProduction: "In production"
        case .shipped: "Shipped"
        case .completed: "Completed"
        case .onHold: "On hold"
        case .rejected: "Rejected"
        case .returned: "Returned"
        case .cancelled: "Cancelled"
        case .unknown: "Unrecognised status"
        }
    }

    /// One line explaining the status, from 3DAPI's docs.
    var meaning: String {
        switch self {
        case .awaitingPayment: "Not paid yet."
        case .paid: "Paid, waiting for a production partner."
        case .assigned: "A production partner has it; production hasn’t started."
        case .inProduction: "Being made."
        case .shipped: "On its way to the customer."
        case .completed: "Delivered and settled."
        case .onHold: "On hold: 3DAPI says there isn’t enough stock to fulfil it."
        case .rejected: "A production partner refused it. 3DAPI reassigns it, or cancels and refunds it."
        case .returned: "Sent back after shipping."
        case .cancelled: "Cancelled, usually with a full refund."
        case .unknown(let word): "3DAPI sent a status Plinth doesn’t recognise (\(word))."
        }
    }

    /// 3DAPI accepts a cancel only for `paid` (not yet started) and `awaiting_payment` (checkout orders, which Plinth
    /// doesn't place). Anything else, including an unknown status, is never offered.
    var canRequestCancellation: Bool { self == .paid || self == .awaitingPayment }

    /// The order was paid for and not cancelled: counted as spend (less refunds), never an unknown status.
    var countsAsPlaced: Bool {
        switch self {
        case .paid, .assigned, .inProduction, .shipped, .completed, .onHold, .rejected, .returned: true
        case .awaitingPayment, .cancelled, .unknown: false
        }
    }

    /// Paid and not yet shipped (the stages "Late" and production notices consider).
    var isBeforeShipping: Bool {
        switch self {
        case .paid, .assigned, .inProduction, .onHold, .rejected: true
        default: false
        }
    }

    /// Shipped or later (tracking is shown).
    var hasShipped: Bool { self == .shipped || self == .completed || self == .returned }

    /// No further change is expected.
    var isFinal: Bool { self == .completed || self == .cancelled || self == .returned }

    var isUnknown: Bool { if case .unknown = self { true } else { false } }
}

/// One catalogue material (`GET /v2/materials`, public).
struct DapiMaterial: Equatable, Hashable, Sendable, Identifiable {
    /// `mat_…`; opaque.
    let id: String
    /// Such as "PLA Red".
    let name: String
    let color: String?
    /// "#RRGGBB" or nil.
    let colorHex: String?
    /// "pla", "petg" and so on (lower-cased), or nil.
    let filamentType: String?
}

/// One extruder slot's material on an order line.
struct DapiMaterialSlot: Equatable, Hashable, Sendable {
    let slot: Int
    let materialID: String
    /// As 3DAPI named it on the order; nil in a request.
    var materialName: String? = nil
}

/// How an order line chooses its materials: the quote's suggestions, or one catalogue material per slot.
enum DapiMaterialChoice: Equatable, Sendable {
    case suggested
    case slots([DapiMaterialSlot])
}

/// What `GET /v2/wallet` says (`wallet:read`). Kept in memory only; optional (a key without the scope gets nil).
struct DapiWallet: Equatable, Sendable {
    let balance: DapiMoney
    let sampleCredit: DapiMoney?
    let sampleCreditExpiresAt: Date?
}

/// One line of an order as 3DAPI returns it (`IntegratorOrderItem`).
struct DapiOrderItem: Equatable, Sendable, Identifiable {
    /// `itm_…`.
    let id: String
    let quoteID: String
    /// The quote's name when ordered: Plinth's neutral "Plinth <16 hex>", or whatever the seller named it elsewhere.
    let quoteName: String?
    let materials: [DapiMaterialSlot]
    let quantity: Int
    /// What was paid per unit (the production price in wallet mode).
    let unitPrice: DapiMoney?
    let productionUnitPrice: DapiMoney?
    let total: DapiMoney?
}

/// `charges`: what was charged. `total` is VAT included, before any sample credit.
struct DapiOrderCharges: Equatable, Sendable {
    /// "you", "buyer" or "dapi" (lower-cased).
    let paidBy: String
    let items: DapiMoney
    let shipping: DapiMoney
    let vat: DapiMoney
    /// 0–1, 0 when none.
    let vatRate: Decimal
    let vatIncluded: Bool
    let vatCountry: String?
    let sampleCredit: DapiMoney?
    let total: DapiMoney
}

/// `shipping`: tier and tracking. There is no tracking URL.
struct DapiOrderShipping: Equatable, Sendable {
    let tier: String?
    let carrier: String?
    let trackingNumber: String?
    let shippedAt: Date?
}

/// A completed refund.
struct DapiRefund: Equatable, Sendable {
    let id: String
    let amount: DapiMoney
    let createdAt: Date?
}

/// A 3DAPI order (`IntegratorOrder`). Customer details and the full address come back only for keys with
/// `orders:read_customer`; Plinth keeps them in memory only and never asks for that scope.
struct DapiOrder: Equatable, Sendable, Identifiable {
    /// `ord_…`; opaque.
    let id: String
    /// "2AP…", the number customers and 3DAPI support use.
    let number: String
    let status: DapiOrderStatus
    /// "wallet" or "checkout".
    let mode: String
    /// The reference Plinth sent (`dapiOrderReference`), or the seller's own from elsewhere.
    let reference: String?
    let customerName: String?
    let customerEmail: String?
    let formattedAddress: String?
    let city: String?
    let countryName: String?
    let countryCode: String?
    let charges: DapiOrderCharges?
    let shipping: DapiOrderShipping
    let itemCount: Int
    /// nil when the list was read without `expand[]=items`.
    let items: [DapiOrderItem]?
    let refunds: [DapiRefund]
    let createdAt: Date?
    let updatedAt: Date?
}

/// A page of `GET /v2/integrator/orders` (newest first by creation).
struct DapiOrderPage: Equatable, Sendable {
    let orders: [DapiOrder]
    let hasMore: Bool
    let nextCursor: String?
}

/// The filters Plinth sends to `GET /v2/integrator/orders`. Every field is optional; `limit` is 1–100.
struct DapiOrderListQuery: Equatable, Sendable {
    var statuses: [DapiOrderStatus] = []
    /// Exact match on `reference` (≤ 100).
    var reference: String? = nil
    /// Part of the number or reference, any case (≤ 100).
    var search: String? = nil
    var createdAfter: Date? = nil
    var createdBefore: Date? = nil
    var cursor: String? = nil
    var limit: Int = 50
    var expandItems: Bool = true
}

/// One line Plinth asks 3DAPI to print.
struct DapiOrderLineRequest: Equatable, Sendable {
    /// A ready, usable quote (`qte_…`).
    let quoteID: String
    /// 1–10,000.
    let quantity: Int
    let materials: DapiMaterialChoice
}

/// The recipient and address Plinth sends. Every field is the seller's typed value, trimmed; `email` is required by
/// 3DAPI and is never invented.
struct DapiOrderRecipient: Equatable, Sendable {
    var name: String
    var email: String
    var phone: String?
    var line1: String
    var line2: String?
    var city: String
    var state: String?
    var postalCode: String?
    /// Upper-case ISO alpha-2.
    var countryCode: String
}

/// A wallet-mode order Plinth places: 1–100 lines, the recipient, the reference (`dapiOrderReference`) and optional notes.
struct DapiOrderRequest: Equatable, Sendable {
    let lines: [DapiOrderLineRequest]
    let recipient: DapiOrderRecipient
    /// `^[A-Za-z0-9_-]{1,100}$`, always carrying Plinth's per-attempt marker.
    let reference: String
    let customerNotes: String?
    /// Sends `use_sample_credit: true` (the seller ticked it): 3DAPI spends sample credit first, only on orders to the
    /// seller's own country; otherwise the order is charged in full. Off unless the seller asks.
    var useSampleCredit: Bool = false
}

/// Everything Plinth asks of 3DAPI for ordering, beside `DapiQuoting`. `DapiClient` conforms to both; tests stub it.
/// No method retries anything: each call sends each request at most once.
protocol DapiOrdering: Sendable {
    /// `GET /v2/materials` (public; sent without the key is fine, but the client may send it), every page (≤ 5).
    func materials() async throws -> [DapiMaterial]
    /// `GET /v2/wallet` (`wallet:read`). A key without the scope is refused (`.refused` 403 `missing_scope`).
    func wallet() async throws -> DapiWallet
    /// One page of `GET /v2/integrator/orders`. Read-only.
    func orders(_ query: DapiOrderListQuery) async throws -> DapiOrderPage
    /// `POST /v2/integrator/orders/shipping-estimate` for every line of an order (creates nothing; excl. VAT).
    func shippingEstimate(lines: [DapiOrderLineRequest], countryCode: String) async throws -> DapiShippingEstimate
    /// `GET /v2/integrator/orders/{id}` with its lines. Read-only.
    func order(id: String) async throws -> DapiOrder
    /// `POST /v2/integrator/orders`, wallet mode: CHARGES AT ONCE. Sent once with `idempotencyKey`, never retried and
    /// never cancelled by Plinth once sent. A failure after sending is `.outcomeUnknown` (408, 5xx, transport,
    /// unreadable) or a definite refusal (`.refused`: 400/402/403/404/409/422 with 3DAPI's error body; nothing charged;
    /// `.rateLimited`: refused, nothing charged).
    func placeOrder(_ request: DapiOrderRequest, idempotencyKey: String) async throws -> DapiOrder
    /// `POST /v2/integrator/orders/{id}/cancel`. Sent once, never retried. 409 `order_not_cancellable` is `.refused`.
    func cancelOrder(id: String, idempotencyKey: String) async throws -> DapiOrder
}

/// Why this 3DAPI account can't place orders yet, or nil when it can: it must be an approved integrator whose key has
/// `orders:write`, with no `order_blockers` (billing details) from onboarding. The Settings implementation may refine
/// the wording; the orders screens show it in place of Place Order.
func dapiOrderingProblem(account: DapiAccount?, onboardingOrderBlockers: [String]) -> String? {
    guard let account else { return "Add a 3DAPI integrator key in Settings › Account first." }
    guard account.isIntegrator else { return dapiDesignerKeyMessage }
    let scopes = Set(account.effectiveScopes.map { $0.trimmingCharacters(in: .whitespaces).lowercased() })
    guard scopes.contains("orders:write") else {
        return "This 3DAPI key can’t place orders. Make a key with orders:write in 3DAPI’s dashboard and save it in Settings › Account."
    }
    guard account.approval?.lowercased() == "approved" else {
        return "3DAPI hasn’t approved this account yet. Ordering opens once 3DAPI approves it."
    }
    if onboardingOrderBlockers.contains(where: { $0.lowercased() == "billing_details_missing" }) {
        return "Add your business billing details in 3DAPI’s dashboard before ordering."
    }
    if let first = onboardingOrderBlockers.first { return "3DAPI says this account can’t order yet (\(first))." }
    return nil
}

// MARK: - Session state shared by the order screens, Settings, the service choice and the quit guard

/// An order whose `POST` went out and whose outcome is unknown. Kept for the whole session in memory only, never
/// cleared by a key or service change (a new key may belong to the same account). Holds no address.
struct DapiUnconfirmedOrder: Equatable, Sendable, Identifiable {
    let id: UUID
    /// The exact reference sent: the read-only `GET /v2/integrator/orders?reference=` lookup finds it.
    let reference: String
    /// The recipient's name as typed (shown in the warning; memory only).
    let recipientName: String
    let countryCode: String
    let units: Int
    let sentAt: Date
}

/// A File menu command the 3DAPI Orders section performs (`DapiOrderSession.toolRequest`). Each only reads or opens
/// a sheet; none sends a write.
enum DapiOrderToolRequest: Equatable, Sendable {
    case reload, spendingReport, exportOrders, trackingForYourShop
}

/// The seller's part of a reference Plinth sent (`dapiOrderReference`): the text before Plinth's "_pl<8 hex>" marker,
/// or nil for Plinth's bare "plinth_<8 hex>" and for an empty reference. Any other reference (made outside Plinth) is
/// returned as it is. Display only: lookups always use the full reference.
func dapiOrderSellerReference(_ reference: String?) -> String? {
    guard let reference = reference?.trimmingCharacters(in: .whitespacesAndNewlines), !reference.isEmpty else { return nil }
    if reference.range(of: "^plinth_[0-9a-f]{8}$", options: .regularExpression) != nil { return nil }
    if let marker = reference.range(of: "_pl[0-9a-f]{8}$", options: .regularExpression) {
        let seller = String(reference[..<marker.lowerBound])
        return seller.isEmpty ? nil : seller
    }
    return reference
}

/// What the Models section asks the 3DAPI composer to start with.
struct DapiComposerPrefill: Equatable, Sendable {
    /// The library model to print (`LocalModel.id`), if any.
    var modelID: UUID? = nil
    var quantity: Int = 1
    /// Upper-case ISO alpha-2, or nil to use the composer's own default.
    var countryCode: String? = nil
    /// Fill the address with the seller's own (Order a Sample to Me).
    var useSellerAddress: Bool = false
}

/// The 3DAPI order screens' session state: writes waiting for a reply, unconfirmed orders, cancels with an unknown
/// outcome, open order sheets, and the composer request from Models. Memory only.
@MainActor final class DapiOrderSession: ObservableObject {
    static let shared = DapiOrderSession()

    /// Place or cancel requests sent and not yet answered.
    @Published private(set) var writesInFlight = 0
    /// Order sheets (composer, review, cancel) currently shown.
    @Published private(set) var openSheets = 0
    /// Orders sent whose outcome is unknown, oldest first.
    @Published private(set) var unconfirmedOrders: [DapiUnconfirmedOrder] = []
    /// Order IDs whose cancel outcome is unknown: no second cancel until a reload shows `cancelled` or 3DAPI refuses.
    @Published private(set) var cancelOutcomeUnknown: Set<String> = []
    /// Set by Models (Order with 3DAPI…, Order a Sample to Me); the Orders section consumes it and sets it back to nil.
    @Published var composerRequest: DapiComposerPrefill?
    /// Set by a clicked 3DAPI order notification (a validated `ord_` ID): the Orders section reads that order by ID
    /// (read-only), selects it and sets this back to nil.
    @Published var orderToShow: String?
    /// Set by the File menu while 3DAPI is the print service; the Orders section performs it and sets it back to nil.
    @Published var toolRequest: DapiOrderToolRequest?

    func beginWrite(_ kind: SlantWriteKind) -> UUID {
        writesInFlight += 1
        return SlantWritesInFlight.shared.begin(kind)
    }

    func endWrite(_ token: UUID) {
        writesInFlight = max(0, writesInFlight - 1)
        SlantWritesInFlight.shared.end(token)
    }

    func sheetOpened() { openSheets += 1 }
    func sheetClosed() { openSheets = max(0, openSheets - 1) }

    func noteUnconfirmedOrder(_ order: DapiUnconfirmedOrder) { unconfirmedOrders.append(order) }

    /// The order with this exact reference was found: its attempt is no longer unconfirmed.
    func confirmUnconfirmedOrder(reference: String) {
        unconfirmedOrders.removeAll { $0.reference == reference }
    }

    func noteCancelOutcomeUnknown(orderID: String) { cancelOutcomeUnknown.insert(orderID) }
    func clearCancelOutcomeUnknown(orderID: String) { cancelOutcomeUnknown.remove(orderID) }

    /// Why the 3DAPI key or the print service can't change now, or nil.
    var changeBlockedReason: String? {
        if writesInFlight > 0 { return "Wait for 3DAPI to answer the order or cancellation first." }
        if openSheets > 0 { return "Close the 3DAPI order sheet first." }
        return nil
    }
}
