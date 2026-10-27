import SwiftUI

// MARK: - Product cost check
//
// Saved Products › Check Cost…: what one saved product costs on Slant today. Each print is priced with the same
// `POST /files/{id}/estimate` read Compare Estimates sends (one at a time, at least 0.6 s apart, stopping when the rate
// limit runs low, never retried); components and stationery use the loaded catalog's prices, with no request.
// Results live in the view while it is open: they are never written to products.json, because saved products hold
// no prices. Delivery isn't priced (Slant only prices it on a draft); the Spending Report's per-country figure is
// pointed to instead.

/// At most this many estimate reads for one check, like one Compare Estimates run.
let productCostMaxEstimates = comparisonMaxCalls

enum ProductCostPartState: Equatable {
    /// A print waiting for its estimate.
    case waiting
    case requesting
    /// `total` is the cost of the whole line in USD.
    case priced(total: Decimal, detail: String)
    /// Can't be priced until the user does something (upload, choose a material, load a catalog); never requested.
    case unavailable(String)
    /// Slant refused or couldn't price it.
    case failed(String)
    /// The check stopped before this print was estimated.
    case notRequested

    var total: Decimal? { if case .priced(let total, _) = self { return total }; return nil }
}

struct ProductCostPart: Equatable, Identifiable {
    let id: Int
    let type: String
    let title: String
    /// Items in one order of the chosen units: per-unit quantities multiplied, once-per-order items once.
    let quantity: Int
    let perOrder: Bool
    /// Prints only: the uploaded file and material to estimate.
    var fileID: String?
    var filamentID: String?
    var state: ProductCostPartState
}

/// Price of a component or stationery record in USD, or why it can't be used. Components document `priceUnit` as a
/// currency (always USD); stationery has no unit field, so its `price` is read as Slant's USD price.
func productCostCatalogPrice(_ record: Record) -> Result<Decimal, StudioError> {
    guard let price = estimateAmount(record.values["price"]), price >= 0 else {
        return .failure(StudioError("Slant lists no price for it."))
    }
    let unit = record.string("priceUnit").trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    guard unit.isEmpty || unit == "USD" else { return .failure(StudioError("Slant prices it in \(unit), so it isn’t added.")) }
    return .success(price)
}

/// The parts of `product` for an order of `units`, each with a catalog price, a print still to estimate, or the
/// reason it can't be priced. Never guesses: a missing upload, material or catalog is explained instead.
func productCostParts(
    _ product: SavedProduct, units: Int, localModels: [LocalModel], filaments: [Record],
    components: [Record], stationery: [Record], loadedCatalogs: Set<Destination>
) -> [ProductCostPart] {
    var parts: [ProductCostPart] = []
    var estimates = 0
    for (index, line) in product.lines.enumerated() {
        var title = savedProductLineTitle(line, localModels: localModels, components: components, stationery: stationery)
        let (multiplied, overflow) = line.quantity.multipliedReportingOverflow(by: max(units, 1))
        let quantity = line.perOrder ? line.quantity : (overflow ? Int.max : multiplied)
        func part(_ state: ProductCostPartState, file: String? = nil, filament: String? = nil) -> ProductCostPart {
            ProductCostPart(id: index, type: line.type, title: title, quantity: max(quantity, 0), perOrder: line.perOrder,
                            fileID: file, filamentID: filament, state: state)
        }
        guard line.quantity > 0 else { parts.append(part(.unavailable("No quantity is set. Edit the product to set one."))); continue }
        guard quantity <= 10_000 else { parts.append(part(.unavailable("More than 10,000 of this item. Choose fewer units."))); continue }
        let reference = line.reference.trimmingCharacters(in: .whitespacesAndNewlines)
        switch line.type {
        case "PRINT":
            let filamentID = line.filamentID.trimmingCharacters(in: .whitespacesAndNewlines)
            if let filament = filaments.first(where: { $0.id == filamentID }) {
                title += " in \(materialDisplayName(displayName(for: filament, fallback: "Untitled material")))"
            }
            var fileID = reference
            if let modelID = line.localModelID {
                if let model = localModels.first(where: { $0.id == modelID }) {
                    let current = model.remoteID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    guard !current.isEmpty else {
                        parts.append(part(.unavailable("“\(model.name)” isn’t uploaded to Slant. Upload it from Models to price it.")))
                        continue
                    }
                    fileID = current
                } else if reference.isEmpty {
                    parts.append(part(.unavailable("Its model is no longer in your library. Edit the product to choose another.")))
                    continue
                }
            }
            guard !fileID.isEmpty else { parts.append(part(.unavailable("Choose a model for this item."))); continue }
            guard !filamentID.isEmpty else { parts.append(part(.unavailable("Choose a material for this item."))); continue }
            if !filaments.isEmpty {
                guard let filament = filaments.first(where: { $0.id == filamentID }) else {
                    parts.append(part(.unavailable("Its material is no longer offered. Edit the product to choose another.")))
                    continue
                }
                if filamentAvailability(filament) == false {
                    parts.append(part(.unavailable("Its material is out of stock, so Slant can’t print it now.")))
                    continue
                }
            }
            guard estimates < productCostMaxEstimates else {
                parts.append(part(.unavailable("Studio estimates up to \(productCostMaxEstimates) prints in one check.")))
                continue
            }
            estimates += 1
            parts.append(part(.waiting, file: fileID, filament: filamentID))
        case "COMPONENT", "STATIONERY":
            let kind: Destination = line.type == "COMPONENT" ? .components : .stationery
            let records = kind == .components ? components : stationery
            let noun = kind == .components ? "Components" : "Stationery"
            guard !reference.isEmpty else { parts.append(part(.unavailable("Choose which \(noun.lowercased()) item to use."))); continue }
            guard loadedCatalogs.contains(kind) || !records.isEmpty else {
                parts.append(part(.unavailable("Load \(noun) in Catalog to include its price.")))
                continue
            }
            guard let record = records.first(where: { $0.id == reference }) else {
                parts.append(part(.unavailable("It’s no longer offered in the catalog.")))
                continue
            }
            // Like an out-of-stock material: Slant marks it not available, so it isn't priced as if it could be ordered.
            if filamentAvailability(record) == false {
                parts.append(part(.unavailable("Slant marks it as not available, so its price isn’t counted.")))
                continue
            }
            switch productCostCatalogPrice(record) {
            case .success(let price):
                let each = money(NSDecimalNumber(decimal: price))
                parts.append(part(.priced(total: price * Decimal(quantity), detail: "Catalog price, \(each) each")))
            case .failure(let reason):
                parts.append(part(.unavailable(reason.message)))
            }
        default:
            parts.append(part(.unavailable("This item has an unknown type.")))
        }
    }
    return parts
}

struct ProductCostSummary: Equatable {
    /// Sum of the parts priced so far, in USD.
    let total: Decimal
    /// `total ÷ units`, to the cent.
    let perUnit: Decimal
    let pricedCount: Int
    let partCount: Int
    var complete: Bool { partCount > 0 && pricedCount == partCount }
}

func productCostSummary(_ parts: [ProductCostPart], units: Int) -> ProductCostSummary {
    let totals = parts.compactMap(\.state.total)
    let total = totals.reduce(Decimal(0), +)
    return ProductCostSummary(total: total, perUnit: roundedToCents(total / Decimal(max(units, 1))),
                              pricedCount: totals.count, partCount: parts.count)
}

/// "$12.40 per unit", or "At least $9.93 per unit" while some parts aren't priced.
func productCostPerUnitText(_ summary: ProductCostSummary) -> String {
    let amount = money(NSDecimalNumber(decimal: summary.perUnit))
    return summary.complete ? "\(amount) per unit" : "At least \(amount) per unit"
}

func productCostCheckedText(_ date: Date, calendar: Calendar = .current) -> String {
    let formatter = DateFormatter()
    formatter.calendar = calendar
    formatter.timeZone = calendar.timeZone
    formatter.locale = calendar.locale ?? .current
    formatter.dateStyle = .medium
    formatter.timeStyle = .short
    return "Checked \(formatter.string(from: date))"
}

/// Detail under a priced print: Slant's estimate, and its price per item when more than one is printed.
func productCostEstimateDetail(_ price: ComparisonPrice) -> String {
    price.quantity > 1
        ? "Slant estimate for \(price.quantity), \(money(NSDecimalNumber(decimal: price.perUnit))) each"
        : "Slant estimate"
}

// MARK: Delivery pointer

struct ProductDeliveryHint: Equatable {
    let countryCode: String
    let orders: Int
    let average: Decimal
}

/// Where loaded orders with this product (its uploaded files or its SKU) most often went, and what Slant charged on
/// average to deliver those orders there, using the Spending Report's rules (charged orders only, USD). Nil without
/// such an order to a recognised country.
func productDeliveryHint(_ product: SavedProduct, localModels: [LocalModel], orders: [Record]) -> ProductDeliveryHint? {
    var fileIDs = Set<String>()
    for line in product.lines where line.type == "PRINT" {
        let reference = line.reference.trimmingCharacters(in: .whitespacesAndNewlines)
        if !reference.isEmpty { fileIDs.insert(reference) }
        if let id = line.localModelID, let remote = localModels.first(where: { $0.id == id })?.remoteID?
            .trimmingCharacters(in: .whitespacesAndNewlines), !remote.isEmpty {
            fileIDs.insert(remote)
        }
    }
    let sku = normalizedSKU(product.sku)
    let matching = orders.filter { record in
        let items = orderObject(record.values)["items"] as? [[String: Any]] ?? []
        return items.contains { item in
            if let file = orderItemFileID(item), fileIDs.contains(file) { return true }
            if !sku.isEmpty, let own = spendReportItemSKU(item), normalizedSKU(own) == sku { return true }
            return false
        }
    }
    guard !matching.isEmpty,
          let top = spendReport(orders: matching).deliveryCosts.first(where: { !$0.countryCode.isEmpty }),
          let average = top.average else { return nil }
    return ProductDeliveryHint(countryCode: top.countryCode, orders: top.orders, average: average)
}

func productDeliveryHintText(_ hint: ProductDeliveryHint?) -> String {
    guard let hint else {
        return "Delivery isn’t included: Slant prices it only when a draft is created. The Spending Report shows what Slant charged per destination country for your orders."
    }
    let country = spendReportCountryTitle(hint.countryCode)
    let orders = hint.orders == 1 ? "1 order" : "\(hint.orders) orders"
    return "Delivery isn’t included. Loaded orders with this product most often went to \(country), where Slant charged \(money(NSDecimalNumber(decimal: hint.average))) on average for delivery (\(orders)). The Spending Report has every country."
}

// MARK: - Runner

@MainActor final class ProductCostCheckRunner: ObservableObject {
    @Published private(set) var parts: [ProductCostPart] = []
    @Published private(set) var units = 1
    @Published private(set) var running = false
    @Published private(set) var message: String?
    @Published private(set) var checkedAt: Date?
    private var task: Task<Void, Never>?
    private var generation = 0
    private var lastRequestStart: Date?
    private var observedRateLimit: RateLimitInfo?
    private var observedAt: Date?
    private var rateLimitedUntil: Date?
    private var requestsThisRun = 0

    var hasResult: Bool { checkedAt != nil || !parts.isEmpty }

    /// Starts a fresh check: every print is estimated again (an explicit request, never an automatic retry).
    func start(_ newParts: [ProductCostPart], units newUnits: Int, store: StudioStore) {
        guard !running else { return }
        parts = newParts
        units = newUnits
        message = nil
        checkedAt = nil
        let pending = newParts.filter { $0.state == .waiting }.map(\.id)
        guard !pending.isEmpty else { checkedAt = Date(); return }
        if let reason = blockingReason(store: store) {
            markWaitingNotRequested()
            message = reason
            return
        }
        generation += 1
        let runGeneration = generation
        running = true
        requestsThisRun = 0
        let client = store.client
        task = Task { [weak self] in
            await self?.execute(pending, client: client, store: store, generation: runGeneration)
        }
    }

    /// Stop button and leaving the view: cancels the estimate in flight and ignores anything that arrives afterwards.
    func stop(store: StudioStore, reason: String?) {
        guard running else { return }
        generation += 1
        task?.cancel()
        task = nil
        finish(store: store, message: reason)
    }

    private func blockingReason(store: StudioStore) -> String? {
        if !store.hasKey || !store.connected { return "Connect your account to check costs." }
        if store.busy { return "Stopped so another Slant task can run. Check again when it finishes." }
        if let until = rateLimitedUntil, until > Date() {
            return "Slant’s rate limit was reached. \(rateLimitResetWaitCopy(secondsFromNow: until.timeIntervalSinceNow))"
        }
        let snapshot = observedRateLimit ?? store.rateLimit
        if case .stop(let reason) = comparisonPacing(rateLimit: snapshot, observedAt: observedRateLimit == nil ? nil : observedAt, now: Date()) {
            return reason
        }
        return nil
    }

    private func markWaitingNotRequested() {
        for index in parts.indices where parts[index].state == .waiting || parts[index].state == .requesting {
            parts[index].state = .notRequested
        }
    }

    private func execute(_ ids: [Int], client: APIClient, store: StudioStore, generation runGeneration: Int) async {
        var consecutiveFailures = 0
        for id in ids {
            guard runGeneration == generation, !Task.isCancelled else { return }
            if let last = lastRequestStart {
                let wait = comparisonMinimumSpacing - Date().timeIntervalSince(last)
                if wait > 0 { try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }
                guard runGeneration == generation, !Task.isCancelled else { return }
            }
            if let reason = blockingReason(store: store) {
                finish(store: store, message: reason)
                return
            }
            guard let index = parts.firstIndex(where: { $0.id == id }), let fileID = parts[index].fileID,
                  let filamentID = parts[index].filamentID else { continue }
            let quantity = parts[index].quantity
            parts[index].state = .requesting
            lastRequestStart = Date()
            requestsThisRun += 1
            do {
                let options: [String: Any] = ["quantity": quantity, "filamentId": filamentID]
                let response = try await client.request("POST", path: "/files/\(encodedSegment(fileID))/estimate", body: ["options": options])
                guard runGeneration == generation else { return }
                if response.rateLimit.hasValues {
                    observedRateLimit = response.rateLimit
                    observedAt = Date()
                    store.rateLimit = response.rateLimit
                }
                switch comparisonPrice(from: responseObject(response), requestedQuantity: quantity) {
                case .priced(let price):
                    parts[index].state = .priced(total: price.total, detail: productCostEstimateDetail(price))
                    consecutiveFailures = 0
                case .unusable(let problem):
                    parts[index].state = .failed(problem)
                    consecutiveFailures += 1
                }
            } catch {
                guard runGeneration == generation else { return }
                if case APIError.http(429, _, let retryAfter, let reset) = error {
                    rateLimitedUntil = comparisonRateLimitedUntil(retryAfter: retryAfter, rateLimitReset: reset, now: Date())
                }
                switch comparisonErrorDisposition(error) {
                case .cancelled:
                    finish(store: store, message: "Stopped before every part was priced.")
                    return
                case .stopRun(let reason):
                    parts[index].state = .failed(reason)
                    finish(store: store, message: reason)
                    return
                case .failCell(let reason):
                    parts[index].state = .failed(reason)
                    consecutiveFailures += 1
                }
            }
            if consecutiveFailures >= comparisonMaxConsecutiveFailures {
                finish(store: store, message: "Stopped after \(comparisonMaxConsecutiveFailures) prints in a row couldn’t be priced.")
                return
            }
        }
        guard runGeneration == generation else { return }
        finish(store: store, message: nil)
    }

    private func finish(store: StudioStore, message newMessage: String?) {
        markWaitingNotRequested()
        running = false
        task = nil
        message = newMessage
        guard requestsThisRun > 0 else { return }
        checkedAt = Date()
        let summary = productCostSummary(parts, units: units)
        // Counts only: no product names, prices or file IDs in Activity.
        store.activities.insert(Activity(title: "Check product cost", detail: "\(summary.pricedCount) of \(summary.partCount) parts priced",
                                         success: newMessage == nil && summary.complete), at: 0)
        store.activities = Array(store.activities.prefix(100))
        requestsThisRun = 0
    }
}

// MARK: - View

/// Shown in place of the Saved Products list (SavedProductsView.swift) for one product; Done goes back to the list.
struct ProductCostCheckView: View {
    @EnvironmentObject var store: StudioStore
    let product: SavedProduct
    let onDone: () -> Void
    @StateObject private var runner = ProductCostCheckRunner()
    @State private var unitsText = "1"

    private var units: Int? { savedProductUnitsSold(unitsText) }
    private var plannedParts: [ProductCostPart] {
        productCostParts(product, units: units ?? 1, localModels: store.localModels, filaments: store.filaments,
                         components: store.components, stationery: store.stationery, loadedCatalogs: store.loadedCatalogs)
    }
    /// The last check's parts while they match the units typed; otherwise what a check would do now.
    private var shownParts: [ProductCostPart] {
        runner.hasResult && runner.units == units ? runner.parts : plannedParts
    }
    private var startBlockedReason: String? {
        if !store.hasKey || !store.connected { return "Connect your account to check costs." }
        if units == nil { return "Enter a whole number of units from 1 to 10,000." }
        if store.busy { return "Wait for the current task to finish." }
        if !plannedParts.contains(where: { $0.state == .waiting }) {
            return plannedParts.contains(where: { $0.type == "PRINT" }) ? "No print can be priced yet. See the notes above." : nil
        }
        return nil
    }

    var body: some View {
        let parts = shownParts
        let shownUnits = runner.hasResult && runner.units == units ? runner.units : (units ?? 1)
        let summary = productCostSummary(parts, units: shownUnits)
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Cost of “\(savedProductDisplayName(product))”").font(.title2.weight(.semibold))
                Text("Fresh Slant estimates for each print, plus catalog prices for components and stationery, in USD. Results stay only while this is open and are never saved with the product.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    unitsRow
                    partsGrid(parts)
                    summaryBlock(summary, units: shownUnits)
                    Label(productDeliveryHintText(productDeliveryHint(product, localModels: store.localModels, orders: store.orders)),
                          systemImage: "shippingbox")
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
            }
            Divider()
            HStack(spacing: 12) {
                Button("Close") { onDone() }
                    .keyboardShortcut(.cancelAction)
                if let message = runner.message {
                    Text(message).font(.caption).foregroundStyle(.orange).lineLimit(3)
                } else if !runner.running, let reason = startBlockedReason {
                    Text(reason).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer()
                if runner.running {
                    Button("Stop") { runner.stop(store: store, reason: "Stopped. Parts already priced are kept.") }
                } else {
                    Button(runner.checkedAt == nil ? "Check Cost" : "Check Again") {
                        guard let units, startBlockedReason == nil else { return }
                        runner.start(plannedParts, units: units, store: store)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(startBlockedReason != nil)
                    .help(startBlockedReason ?? "Ask Slant for an estimate of each print, one at a time")
                }
            }
            .padding(16)
            .background(.bar)
        }
        .onDisappear { runner.stop(store: store, reason: nil) }
    }

    private var unitsRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text("Units in order")
                TextField("Units in order", text: $unitsText)
                    .labelsHidden()
                    // Hidden labels aren't read by VoiceOver on macOS, so name the field explicitly.
                    .accessibilityLabel("Units in order")
                    .frame(width: 64)
                    .disabled(runner.running)
            }
            if units == nil {
                Text("Enter a whole number of units from 1 to 10,000.").font(.caption).foregroundStyle(.orange)
            } else {
                Text("Prices one order of this many units. Per-unit items are multiplied; once-per-order items are added once.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func partsGrid(_ parts: [ProductCostPart]) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 8) {
            GridRow {
                Text("Part"); Text("Quantity").gridColumnAlignment(.trailing); Text("Cost").gridColumnAlignment(.trailing)
            }
            .font(.caption).foregroundStyle(.secondary)
            ForEach(parts) { part in
                GridRow(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(part.title).lineLimit(2)
                        partNote(part)
                    }
                    Text(part.perOrder ? "\(part.quantity) per order" : "\(part.quantity)").monospacedDigit()
                    partCost(part)
                }
            }
        }
        .textSelection(.enabled)
    }

    @ViewBuilder
    private func partNote(_ part: ProductCostPart) -> some View {
        switch part.state {
        case .priced(_, let detail): Text(detail).font(.caption).foregroundStyle(.secondary)
        case .unavailable(let reason), .failed(let reason):
            Label(reason, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        case .waiting: Text(runner.running ? "Waiting" : "Estimated when you check").font(.caption).foregroundStyle(.secondary)
        case .requesting: Text("Estimating…").font(.caption).foregroundStyle(.secondary)
        case .notRequested: Text("Not estimated").font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func partCost(_ part: ProductCostPart) -> some View {
        if case .requesting = part.state {
            ProgressView().controlSize(.small)
        } else if let total = part.state.total {
            Text(money(NSDecimalNumber(decimal: total))).monospacedDigit()
        } else {
            Text("—").foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func summaryBlock(_ summary: ProductCostSummary, units: Int) -> some View {
        if summary.pricedCount > 0 {
            VStack(alignment: .leading, spacing: 4) {
                Text(productCostPerUnitText(summary)).font(.title3.weight(.semibold)).monospacedDigit()
                Text("\(money(NSDecimalNumber(decimal: summary.total))) for an order of \(units) \(units == 1 ? "unit" : "units"), before delivery")
                    .font(.callout).foregroundStyle(.secondary)
                if !summary.complete {
                    Text("\(summary.partCount - summary.pricedCount) of \(summary.partCount) parts aren’t priced, so the real cost is higher.")
                        .font(.caption).foregroundStyle(.orange)
                }
                if let checkedAt = runner.checkedAt, runner.units == units {
                    Text("\(productCostCheckedText(checkedAt)). Estimates can change; Slant prices the order itself when a draft is created.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}
