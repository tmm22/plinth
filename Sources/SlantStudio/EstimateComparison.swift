import SwiftUI

// MARK: - Compare estimates
//
// Slant's `POST /files/{id}/estimate` prices one material at one quantity per call, so this sheet runs a small,
// explicit batch of those reads one at a time and lays the results out side by side. Estimates are side-effect free;
// nothing here creates, charges or cancels anything, and no request is retried automatically.

let comparisonMaxMaterials = 4
let comparisonMaxQuantities = 5
let comparisonMaxCalls = 20
let comparisonDefaultQuantityText = "1, 5, 10, 25, 50"
/// Requests left this minute that the comparison leaves for the rest of the app (uploads, order drafts, reloads).
let comparisonRateLimitReserve = 10
/// Never start requests faster than Slant's documented average rate (100 requests a minute).
let comparisonMinimumSpacing: TimeInterval = 0.6
/// Consecutive per-cell failures after which the run stops instead of spending more requests.
let comparisonMaxConsecutiveFailures = 3
let comparisonPrintOnlyNotice = "Print cost estimate only — delivery is priced when you create an order draft."

// MARK: Quantities

struct ComparisonQuantityInput: Equatable {
    var values: [Int]
    var problem: String?
}

/// Parses "1, 5, 10" style input into sorted, de-duplicated whole numbers using the same 1…10,000 rule as the
/// Models quantity field. Ambiguous text such as "1,500" is refused rather than guessed.
func parseComparisonQuantities(_ text: String, maxCount: Int = comparisonMaxQuantities) -> ComparisonQuantityInput {
    if text.range(of: #"\d,\d{3}(?!\d)"#, options: .regularExpression) != nil {
        return ComparisonQuantityInput(values: [], problem: "Write large numbers without a comma (1500, not 1,500), and separate quantities with a comma and a space.")
    }
    let separators = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ",;"))
    let tokens = text.components(separatedBy: separators).filter { !$0.isEmpty }
    guard !tokens.isEmpty else { return ComparisonQuantityInput(values: [], problem: "Enter at least one quantity.") }
    var values = Set<Int>()
    for token in tokens {
        guard let value = printQuantity(token) else {
            let shown = token.count > 12 ? String(token.prefix(12)) + "…" : token
            return ComparisonQuantityInput(values: [], problem: "“\(shown)” isn’t a whole number from 1 to 10,000.")
        }
        values.insert(value)
    }
    let sorted = values.sorted()
    guard sorted.count <= maxCount else {
        return ComparisonQuantityInput(values: [], problem: "Enter up to \(maxCount) different quantities.")
    }
    return ComparisonQuantityInput(values: sorted, problem: nil)
}

// MARK: Plan

struct ComparisonMaterial: Equatable, Identifiable {
    let id: String
    let name: String
}

struct ComparisonCellKey: Hashable {
    let filamentID: String
    let quantity: Int
}

struct ComparisonPlan: Equatable {
    let fileID: String
    let materials: [ComparisonMaterial]
    let quantities: [Int]
    /// Request order: every quantity for the first material, then the next, so whole columns finish first.
    var cells: [ComparisonCellKey] {
        materials.flatMap { material in quantities.map { ComparisonCellKey(filamentID: material.id, quantity: $0) } }
    }
}

/// Materials × quantities, de-duplicated and capped so a single run never exceeds `maxCalls` estimates.
func comparisonPlan(fileID: String, materials: [ComparisonMaterial], quantities: [Int],
                    maxMaterials: Int = comparisonMaxMaterials, maxQuantities: Int = comparisonMaxQuantities,
                    maxCalls: Int = comparisonMaxCalls) -> ComparisonPlan {
    var seen = Set<String>()
    let uniqueMaterials = materials.filter { !$0.id.isEmpty && seen.insert($0.id).inserted }
    let cleanQuantities = Array(Set(quantities.filter { (1...10000).contains($0) }).sorted().prefix(max(0, maxQuantities)))
    let perMaterial = max(1, cleanQuantities.count)
    let materialLimit = min(max(0, maxMaterials), max(0, maxCalls) / perMaterial)
    return ComparisonPlan(fileID: fileID, materials: Array(uniqueMaterials.prefix(materialLimit)), quantities: cleanQuantities)
}

/// In-stock materials offered in the picker, keeping Slant's order within each material type.
func comparisonMaterialChoices(_ filaments: [Record]) -> [ComparisonMaterial] {
    let available = filaments.filter { filamentAvailability($0) != false && !$0.id.isEmpty }
    let types = filamentTypes(in: available)
    return types.flatMap { type in
        available.filter { filamentType($0) == type }.map { ComparisonMaterial(id: $0.id, name: filamentPickerLabel($0)) }
    }
}

/// The comparison starts with the material already chosen in Print configuration, when it can be priced.
func comparisonDefaultMaterialIDs(selectedFilamentID: String, choices: [ComparisonMaterial]) -> [String] {
    choices.contains { $0.id == selectedFilamentID } ? [selectedFilamentID] : []
}

// MARK: Prices

struct ComparisonPrice: Equatable {
    let total: Decimal
    let quantity: Int
    /// Total ÷ quantity, rounded to the cent as shown.
    let perUnit: Decimal
}

func roundedToCents(_ value: Decimal) -> Decimal {
    var input = value
    var output = Decimal()
    NSDecimalRound(&output, &input, 2, .plain)
    return output
}

func estimateAmount(_ value: Any?) -> Decimal? {
    let decimal: Decimal?
    if let number = value as? NSNumber {
        if CFGetTypeID(number) == CFBooleanGetTypeID() { return nil }
        decimal = number.decimalValue
    } else if let string = value as? String {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.range(of: #"^-?\d+(\.\d+)?$"#, options: .regularExpression) != nil else { return nil }
        decimal = Decimal(string: trimmed, locale: Locale(identifier: "en_US_POSIX"))
    } else {
        decimal = nil
    }
    guard let decimal, !decimal.isNaN else { return nil }
    return decimal
}

func comparisonPerUnit(total: Decimal, quantity: Int) -> Decimal? {
    guard quantity > 0 else { return nil }
    return roundedToCents(total / Decimal(quantity))
}

enum ComparisonPriceResult: Equatable {
    case priced(ComparisonPrice)
    case unusable(String)
}

/// Reads `total` (print cost in USD, no delivery) from an estimate response and checks it priced what was asked.
func comparisonPrice(from estimate: [String: Any], requestedQuantity: Int) -> ComparisonPriceResult {
    if let returned = estimate["quantity"], !(returned is NSNull) {
        let value = (returned as? NSNumber)?.intValue ?? (returned as? String).flatMap { Int($0) }
        if let value, value != requestedQuantity {
            return .unusable("Slant priced \(value) instead of \(requestedQuantity).")
        }
    }
    guard let total = estimateAmount(estimate["total"]), total >= 0,
          let perUnit = comparisonPerUnit(total: total, quantity: requestedQuantity) else {
        return .unusable("Slant didn’t return a total for this estimate.")
    }
    return .priced(ComparisonPrice(total: total, quantity: requestedQuantity, perUnit: perUnit))
}

/// True when at least two quantities were priced and every one costs the same per unit (to the cent).
func isFlatPerUnitPricing(_ perUnits: [Decimal]) -> Bool {
    guard perUnits.count >= 2, let first = perUnits.first.map(roundedToCents) else { return false }
    return perUnits.allSatisfy { roundedToCents($0) == first }
}

/// Quantities with the lowest per-unit price; empty when fewer than two are priced or pricing is flat.
func cheapestPerUnitQuantities(_ prices: [ComparisonPrice]) -> Set<Int> {
    guard prices.count >= 2, !isFlatPerUnitPricing(prices.map(\.perUnit)),
          let lowest = prices.map({ roundedToCents($0.perUnit) }).min() else { return [] }
    return Set(prices.filter { roundedToCents($0.perUnit) == lowest }.map(\.quantity))
}

// MARK: Results table

enum ComparisonCellState: Equatable {
    case waiting, requesting, priced(ComparisonPrice), failed(String), notRequested
    var price: ComparisonPrice? { if case .priced(let price) = self { return price }; return nil }
}

struct ComparisonTableCell: Equatable {
    let key: ComparisonCellKey
    let state: ComparisonCellState
    let isCheapest: Bool
}

struct ComparisonTableRow: Equatable {
    let quantity: Int
    let cells: [ComparisonTableCell]
}

struct ComparisonTable: Equatable {
    let materials: [ComparisonMaterial]
    let rows: [ComparisonTableRow]
    let flatMaterialIDs: [String]
    let pricedCount: Int
    let totalCount: Int
    let flatPricingNote: String?
}

func comparisonTable(plan: ComparisonPlan, states: [ComparisonCellKey: ComparisonCellState]) -> ComparisonTable {
    var cheapest: [String: Set<Int>] = [:]
    var flat: [ComparisonMaterial] = []
    var comparable: [ComparisonMaterial] = []
    for material in plan.materials {
        let prices = plan.quantities.compactMap { states[ComparisonCellKey(filamentID: material.id, quantity: $0)]?.price }
        cheapest[material.id] = cheapestPerUnitQuantities(prices)
        guard prices.count >= 2 else { continue }
        comparable.append(material)
        if isFlatPerUnitPricing(prices.map(\.perUnit)) { flat.append(material) }
    }
    let rows = plan.quantities.map { quantity in
        ComparisonTableRow(quantity: quantity, cells: plan.materials.map { material in
            let key = ComparisonCellKey(filamentID: material.id, quantity: quantity)
            return ComparisonTableCell(key: key, state: states[key] ?? .notRequested,
                                       isCheapest: cheapest[material.id]?.contains(quantity) == true)
        })
    }
    let note: String?
    if flat.isEmpty {
        note = nil
    } else if flat.count == comparable.count {
        note = "Slant’s price per unit doesn’t change with quantity for this model."
    } else {
        note = "In \(flat.map(\.name).joined(separator: ", ")), Slant’s price per unit doesn’t change with quantity for this model."
    }
    let priced = plan.cells.filter { states[$0]?.price != nil }.count
    return ComparisonTable(materials: plan.materials, rows: rows, flatMaterialIDs: flat.map(\.id),
                           pricedCount: priced, totalCount: plan.cells.count, flatPricingNote: note)
}

// MARK: Run rules

func compareEstimatesBlockedReason(hasKey: Bool, connected: Bool, fileID: String, filaments: [Record], busy: Bool) -> String? {
    if !hasKey || !connected { return "Connect your account to compare estimates." }
    if fileID.isEmpty { return "Upload this model to compare estimates." }
    if filaments.isEmpty { return "Load materials to compare estimates." }
    if !filaments.contains(where: { filamentAvailability($0) != false }) { return "No materials are in stock right now." }
    if busy { return "Wait for the current task to finish." }
    return nil
}

/// Checked before every request: the comparison yields to other work and stops if its model or account changes.
func comparisonRunInterruption(hasKey: Bool, connected: Bool, busy: Bool, currentFileID: String, planFileID: String) -> String? {
    if !hasKey || !connected { return "Stopped because the account is no longer connected." }
    if currentFileID != planFileID { return "Stopped because a different model or upload is selected." }
    if busy { return "Stopped so another Slant task can run. Get the remaining estimates when it finishes." }
    return nil
}

enum ComparisonPacing: Equatable {
    case proceed
    case stop(String)
}

/// Stops (never waits and retries) when Slant's rate-limit headers show the minute's allowance nearly used.
/// Without a reset time, a low remaining count is only trusted for a minute after it was observed.
func comparisonPacing(rateLimit: RateLimitInfo?, observedAt: Date?, now: Date, reserve: Int = comparisonRateLimitReserve) -> ComparisonPacing {
    guard let rateLimit, let remaining = rateLimit.remaining, remaining <= reserve else { return .proceed }
    let allowance = rateLimit.limit.map { "Slant allows \($0) requests a minute and \(remaining) are left" } ?? "Only \(remaining) Slant requests are left this minute"
    let lead = "Paused to stay within Slant’s rate limit. \(allowance), so the rest are kept for uploads and orders."
    if let reset = rateLimit.reset {
        guard reset > now else { return .proceed }
        return .stop("\(lead) \(rateLimitResetWaitCopy(secondsFromNow: reset.timeIntervalSince(now)))")
    }
    guard let observedAt, now.timeIntervalSince(observedAt) < 60 else { return .proceed }
    return .stop("\(lead) Try again in about a minute.")
}

/// After a 429, when Slant says requests may resume: the reset time, else a numeric Retry-After, else a minute.
func comparisonRateLimitedUntil(retryAfter: String?, rateLimitReset: String?, now: Date) -> Date {
    if let raw = rateLimitReset?.trimmingCharacters(in: .whitespaces), let seconds = TimeInterval(raw), seconds > now.timeIntervalSince1970 {
        return Date(timeIntervalSince1970: min(seconds, now.timeIntervalSince1970 + 3600))
    }
    if let raw = retryAfter?.trimmingCharacters(in: .whitespaces), let seconds = TimeInterval(raw), seconds > 0 {
        return now.addingTimeInterval(min(seconds, 3600))
    }
    return now.addingTimeInterval(60)
}

enum ComparisonErrorDisposition: Equatable {
    /// The user stopped or closed the sheet.
    case cancelled
    /// Every remaining request would fail the same way (rate limit, key, missing file, outage, network).
    case stopRun(String)
    /// Only this material/quantity was refused.
    case failCell(String)
}

func comparisonErrorDisposition(_ error: Error) -> ComparisonErrorDisposition {
    if error is CancellationError { return .cancelled }
    if let urlError = error as? URLError, urlError.code == .cancelled { return .cancelled }
    if let api = error as? APIError {
        switch api {
        case .http(let status, _, _, _):
            switch status {
            case 429: return .stopRun("Stopped: Slant’s rate limit was reached. \(api.userMessage)")
            case 400, 422: return .failCell(api.userMessage)
            default: return .stopRun("Stopped: \(api.userMessage)")
            }
        case .invalidResponse: return .failCell(api.userMessage)
        case .invalidRequest, .keychain: return .stopRun("Stopped: \(api.userMessage)")
        }
    }
    return .stopRun("Stopped: \(friendlyAPIMessage(error))")
}

/// Same key format as `StudioStore.estimateIsCurrent`. If the two ever drift, a reused estimate simply shows as
/// stale and asks for a new one, which is the safe direction.
func comparisonEstimateContext(fileID: String, filamentID: String, quantity: Int) -> String {
    "\(fileID)|\(filamentID)|\(quantity)"
}

func comparisonUseBlockedReason(planFileID: String, currentFileID: String, filamentID: String, filaments: [Record], busy: Bool) -> String? {
    if busy { return "Wait for the current task to finish." }
    if planFileID != currentFileID { return "These estimates are for a different model or upload." }
    guard let filament = filaments.first(where: { $0.id == filamentID }) else { return "This material is no longer offered." }
    if filamentAvailability(filament) == false { return "This material is now out of stock." }
    return nil
}

func comparisonCompletionSummary(priced: Int, total: Int, failed: Int) -> String {
    var text = "\(priced) of \(total) estimates in"
    if failed > 0 { text += " · \(failed) couldn’t be priced" }
    return text
}

// MARK: - Store hook

extension StudioStore {
    /// Applies a compared cell only on the user's explicit "Use". The comparison response is the same request
    /// `quote()` makes (same file, `filamentId` and `quantity`), so it becomes the current estimate under the same
    /// context key; any later change to material or quantity marks it stale as usual.
    func useComparedEstimate(fileID chosenFileID: String, filamentID chosenFilament: String, quantity chosenQuantity: Int,
                             estimate response: [String: Any]?, materialName: String) {
        guard chosenFileID == fileID, printQuantity(String(chosenQuantity)) != nil else { return }
        filamentID = chosenFilament
        quantity = chosenQuantity
        if let response {
            estimate = response
            estimateContext = comparisonEstimateContext(fileID: chosenFileID, filamentID: chosenFilament, quantity: chosenQuantity)
        }
        activities.insert(Activity(title: "Use compared estimate", detail: "\(materialName) × \(chosenQuantity)", success: true), at: 0)
        activities = Array(activities.prefix(100))
    }
}

// MARK: - Runner

@MainActor final class EstimateComparisonRunner: ObservableObject {
    @Published private(set) var plan: ComparisonPlan?
    @Published private(set) var states: [ComparisonCellKey: ComparisonCellState] = [:]
    @Published private(set) var running = false
    @Published private(set) var message: String?
    private(set) var responses: [ComparisonCellKey: [String: Any]] = [:]
    private var task: Task<Void, Never>?
    private var generation = 0
    private var lastRequestStart: Date?
    private var observedRateLimit: RateLimitInfo?
    private var observedAt: Date?
    private var rateLimitedUntil: Date?
    private var requestsThisRun = 0

    var remainingCells: [ComparisonCellKey] {
        plan?.cells.filter { states[$0]?.price == nil } ?? []
    }

    /// Starts a run for `newPlan`. Prices already fetched for the same upload in this sheet are kept, not re-requested.
    func start(_ newPlan: ComparisonPlan, store: StudioStore) {
        guard !running, !newPlan.cells.isEmpty else { return }
        var carried: [ComparisonCellKey: ComparisonCellState] = [:]
        var carriedResponses: [ComparisonCellKey: [String: Any]] = [:]
        if plan?.fileID == newPlan.fileID {
            for key in newPlan.cells {
                if let state = states[key], state.price != nil { carried[key] = state; carriedResponses[key] = responses[key] }
            }
        }
        plan = newPlan
        responses = carriedResponses
        let pending = newPlan.cells.filter { carried[$0] == nil }
        for key in pending { carried[key] = .waiting }
        states = carried
        message = nil
        guard !pending.isEmpty else { return }
        if let reason = blockingReason(store: store, fileID: newPlan.fileID) {
            for key in pending { states[key] = .notRequested }
            message = reason
            return
        }
        generation += 1
        let runGeneration = generation
        running = true
        requestsThisRun = 0
        let client = store.client
        task = Task { [weak self] in
            await self?.execute(pending, fileID: newPlan.fileID, client: client, store: store, generation: runGeneration)
        }
    }

    /// Stop button and sheet close: cancels the in-flight read and ignores anything that arrives afterwards.
    func stop(store: StudioStore, reason: String?) {
        guard running else { return }
        generation += 1
        task?.cancel()
        task = nil
        finish(store: store, message: reason)
    }

    private func blockingReason(store: StudioStore, fileID: String) -> String? {
        if let interruption = comparisonRunInterruption(hasKey: store.hasKey, connected: store.connected, busy: store.busy,
                                                        currentFileID: store.fileID, planFileID: fileID) {
            return interruption
        }
        if let until = rateLimitedUntil, until > Date() {
            return "Slant’s rate limit was reached. \(rateLimitResetWaitCopy(secondsFromNow: until.timeIntervalSinceNow))"
        }
        let snapshot = observedRateLimit ?? store.rateLimit
        if case .stop(let reason) = comparisonPacing(rateLimit: snapshot, observedAt: observedRateLimit == nil ? nil : observedAt, now: Date()) {
            return reason
        }
        return nil
    }

    private func execute(_ keys: [ComparisonCellKey], fileID: String, client: APIClient, store: StudioStore, generation runGeneration: Int) async {
        var consecutiveFailures = 0
        for key in keys {
            guard runGeneration == generation, !Task.isCancelled else { return }
            if let last = lastRequestStart {
                let wait = comparisonMinimumSpacing - Date().timeIntervalSince(last)
                if wait > 0 { try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }
                guard runGeneration == generation, !Task.isCancelled else { return }
            }
            if let reason = blockingReason(store: store, fileID: fileID) {
                finish(store: store, message: reason)
                return
            }
            states[key] = .requesting
            lastRequestStart = Date()
            requestsThisRun += 1
            do {
                let options: [String: Any] = ["quantity": key.quantity, "filamentId": key.filamentID]
                let response = try await client.request("POST", path: "/files/\(encodedSegment(fileID))/estimate", body: ["options": options])
                guard runGeneration == generation else { return }
                observedRateLimit = response.rateLimit
                observedAt = Date()
                store.rateLimit = response.rateLimit
                let object = responseObject(response)
                switch comparisonPrice(from: object, requestedQuantity: key.quantity) {
                case .priced(let price):
                    states[key] = .priced(price)
                    responses[key] = object
                    consecutiveFailures = 0
                case .unusable(let problem):
                    states[key] = .failed(problem)
                    consecutiveFailures += 1
                }
            } catch {
                guard runGeneration == generation else { return }
                if case APIError.http(429, _, let retryAfter, let reset) = error {
                    rateLimitedUntil = comparisonRateLimitedUntil(retryAfter: retryAfter, rateLimitReset: reset, now: Date())
                }
                switch comparisonErrorDisposition(error) {
                case .cancelled:
                    finish(store: store, message: "Stopped before every estimate was in. Prices already in are kept.")
                    return
                case .stopRun(let reason):
                    finish(store: store, message: reason)
                    return
                case .failCell(let reason):
                    states[key] = .failed(reason)
                    consecutiveFailures += 1
                }
            }
            if consecutiveFailures >= comparisonMaxConsecutiveFailures {
                finish(store: store, message: "Stopped after \(comparisonMaxConsecutiveFailures) estimates in a row couldn’t be priced. Check the materials and quantities, then try again.")
                return
            }
        }
        guard runGeneration == generation else { return }
        finish(store: store, message: nil)
    }

    private func finish(store: StudioStore, message newMessage: String?) {
        for (key, state) in states where state == .waiting || state == .requesting { states[key] = .notRequested }
        running = false
        task = nil
        message = newMessage
        guard requestsThisRun > 0, let plan else { return }
        let failed = plan.cells.filter { if case .failed = states[$0] { return true }; return false }.count
        let table = comparisonTable(plan: plan, states: states)
        var detail = comparisonCompletionSummary(priced: table.pricedCount, total: table.totalCount, failed: failed)
        if let newMessage { detail += " · \(newMessage)" }
        store.activities.insert(Activity(title: "Compare estimates", detail: detail,
                                         success: newMessage == nil && failed == 0), at: 0)
        store.activities = Array(store.activities.prefix(100))
        requestsThisRun = 0
    }
}

// MARK: - Views

/// The single hook in Print configuration.
struct CompareEstimatesButton: View {
    @EnvironmentObject var store: StudioStore
    let modelName: String
    @State private var showing = false

    var body: some View {
        let reason = compareEstimatesBlockedReason(hasKey: store.hasKey, connected: store.connected, fileID: store.fileID,
                                                   filaments: store.filaments, busy: store.busy)
        HStack(spacing: 10) {
            Button("Compare estimates…") { showing = true }
                .buttonStyle(.bordered)
                .disabled(reason != nil)
                .help(reason ?? "Price up to \(comparisonMaxMaterials) materials at up to \(comparisonMaxQuantities) quantities side by side")
            if let reason, !store.busy {
                Text(reason).font(.caption).foregroundStyle(.secondary)
            }
        }
        .sheet(isPresented: $showing) {
            EstimateComparisonSheet(modelName: modelName).environmentObject(store)
        }
    }
}

struct EstimateComparisonSheet: View {
    @EnvironmentObject var store: StudioStore
    @Environment(\.dismiss) private var dismiss
    let modelName: String
    @StateObject private var runner = EstimateComparisonRunner()
    @State private var selectedMaterialIDs: [String] = []
    @State private var quantityText = comparisonDefaultQuantityText
    @State private var didSetDefaults = false

    private var choices: [ComparisonMaterial] { comparisonMaterialChoices(store.filaments) }
    /// Ticked materials that can still be priced; one that went out of stock after a refresh drops out.
    private var activeSelection: [String] { selectedMaterialIDs.filter { id in choices.contains { $0.id == id } } }
    private var quantityInput: ComparisonQuantityInput { parseComparisonQuantities(quantityText) }
    private var draftPlan: ComparisonPlan {
        let chosen = activeSelection.compactMap { id in choices.first { $0.id == id } }
        return comparisonPlan(fileID: store.fileID, materials: chosen, quantities: quantityInput.values)
    }
    private var startBlockedReason: String? {
        if let reason = compareEstimatesBlockedReason(hasKey: store.hasKey, connected: store.connected, fileID: store.fileID,
                                                      filaments: store.filaments, busy: store.busy) { return reason }
        if draftPlan.materials.isEmpty { return "Choose at least one material." }
        if let problem = quantityInput.problem { return problem }
        return nil
    }
    private var planMatchesInputs: Bool { runner.plan == draftPlan }
    private var startTitle: String {
        if planMatchesInputs, !runner.remainingCells.isEmpty, runner.remainingCells.count < draftPlan.cells.count {
            return "Get remaining estimates"
        }
        return "Get estimates"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Compare estimates").font(.title2.weight(.bold))
                Text(modelName).font(.callout).foregroundStyle(.secondary).lineLimit(1)
            }
            .padding(24)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    materialSection
                    quantitySection
                    Label(comparisonPrintOnlyNotice, systemImage: "info.circle")
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let plan = runner.plan {
                        resultsSection(comparisonTable(plan: plan, states: runner.states), plan: plan)
                    }
                }
                .padding(24)
            }
            Divider()
            footer.padding(20)
        }
        .frame(width: 780, height: 680)
        .onAppear {
            guard !didSetDefaults else { return }
            didSetDefaults = true
            selectedMaterialIDs = comparisonDefaultMaterialIDs(selectedFilamentID: store.filamentID, choices: choices)
            Task { await store.refreshFilamentsIfStale() }
        }
        .onDisappear { runner.stop(store: store, reason: nil) }
    }

    private var materialSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Materials").font(.headline)
                Spacer()
                Text("\(activeSelection.count) of up to \(comparisonMaxMaterials)")
                    .font(.caption).foregroundStyle(.secondary)
            }
            List {
                ForEach(choices) { material in
                    Toggle(material.name, isOn: materialBinding(material.id))
                        .toggleStyle(.checkbox)
                        .disabled(runner.running || (!activeSelection.contains(material.id) && activeSelection.count >= comparisonMaxMaterials))
                }
            }
            .frame(height: 150)
            .listStyle(.bordered(alternatesRowBackgrounds: true))
            let hidden = store.filaments.filter { filamentAvailability($0) == false }.count
            if hidden > 0 {
                Text("\(hidden) out-of-stock material\(hidden == 1 ? " isn’t" : "s aren’t") listed.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var quantitySection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Quantities").font(.headline)
            TextField("1, 5, 10, 25, 50", text: $quantityText)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 320)
                .disabled(runner.running)
                .accessibilityLabel("Quantities to compare")
            if let problem = quantityInput.problem {
                Label(problem, systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(.orange)
            } else {
                Text("Up to \(comparisonMaxQuantities) whole numbers from 1 to 10,000, separated by commas or spaces. Will price: \(quantityInput.values.map(String.init).joined(separator: ", ")).")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func resultsSection(_ table: ComparisonTable, plan: ComparisonPlan) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Results").font(.headline)
                Spacer()
                Text(runner.running ? "Estimating one at a time · \(table.pricedCount) of \(table.totalCount) in" : "\(table.pricedCount) of \(table.totalCount) estimates in")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if plan.fileID != store.fileID {
                Label("These estimates are for a different model or upload.", systemImage: "exclamationmark.triangle")
                    .font(.callout).foregroundStyle(.orange)
            }
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                GridRow {
                    Text("Quantity").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    ForEach(table.materials) { material in
                        Text(material.name).font(.caption.weight(.semibold)).lineLimit(2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                Divider().gridCellUnsizedAxes(.horizontal)
                ForEach(table.rows, id: \.quantity) { row in
                    GridRow(alignment: .top) {
                        Text("\(row.quantity)").font(.body.monospacedDigit())
                        ForEach(row.cells, id: \.key) { cell in
                            cellView(cell, plan: plan)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
            }
            if let note = table.flatPricingNote {
                Label(note, systemImage: "equal.circle").font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("Each = Slant’s total ÷ quantity, so any multi-part or oversize charges in the total are spread across the units. Lowest per unit is marked within each material.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func cellView(_ cell: ComparisonTableCell, plan: ComparisonPlan) -> some View {
        switch cell.state {
        case .waiting:
            Text("Waiting").font(.caption).foregroundStyle(.secondary)
        case .requesting:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Estimating…").font(.caption).foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
        case .notRequested:
            Text("Not requested").font(.caption).foregroundStyle(.secondary)
        case .failed(let reason):
            Label("Couldn’t price", systemImage: "exclamationmark.triangle")
                .font(.caption).foregroundStyle(.orange)
                .help(reason)
                .accessibilityLabel("Couldn’t price. \(reason)")
        case .priced(let price):
            let useReason = comparisonUseBlockedReason(planFileID: plan.fileID, currentFileID: store.fileID,
                                                       filamentID: cell.key.filamentID, filaments: store.filaments, busy: store.busy)
            VStack(alignment: .leading, spacing: 3) {
                Text("\(money(NSDecimalNumber(decimal: price.total))) total").font(.callout.weight(.semibold).monospacedDigit())
                Text("\(money(NSDecimalNumber(decimal: price.perUnit))) each").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                if cell.isCheapest {
                    StudioBadge(text: "Lowest per unit", tone: .success)
                }
                Button("Use") { use(cell.key, plan: plan) }
                    .controlSize(.small)
                    .disabled(useReason != nil)
                    .help(useReason ?? "Set Print configuration to this material and quantity")
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Button("Done") { dismiss() }
                .keyboardShortcut(.cancelAction)
            if let message = runner.message {
                Text(message).font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            } else if !runner.running, let reason = startBlockedReason {
                Text(reason).font(.caption).foregroundStyle(.secondary)
            } else if !runner.running, planMatchesInputs, runner.remainingCells.isEmpty {
                Text("All estimates are in.").font(.caption).foregroundStyle(.secondary)
            } else {
                Text("Up to \(draftPlan.cells.count) estimate\(draftPlan.cells.count == 1 ? "" : "s"), requested one at a time.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if runner.running {
                Button("Stop") { runner.stop(store: store, reason: "Stopped. Prices already in are kept.") }
            } else {
                Button(startTitle) { runner.start(draftPlan, store: store) }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(startBlockedReason != nil || (planMatchesInputs && runner.remainingCells.isEmpty))
            }
        }
    }

    private func materialBinding(_ id: String) -> Binding<Bool> {
        Binding(
            get: { selectedMaterialIDs.contains(id) },
            set: { isOn in
                if isOn {
                    selectedMaterialIDs = activeSelection
                    if !selectedMaterialIDs.contains(id), selectedMaterialIDs.count < comparisonMaxMaterials { selectedMaterialIDs.append(id) }
                } else {
                    selectedMaterialIDs.removeAll { $0 == id }
                }
            }
        )
    }

    private func use(_ key: ComparisonCellKey, plan: ComparisonPlan) {
        guard comparisonUseBlockedReason(planFileID: plan.fileID, currentFileID: store.fileID, filamentID: key.filamentID,
                                         filaments: store.filaments, busy: store.busy) == nil else { return }
        let name = plan.materials.first { $0.id == key.filamentID }?.name ?? "Material"
        store.useComparedEstimate(fileID: plan.fileID, filamentID: key.filamentID, quantity: key.quantity,
                                  estimate: runner.responses[key], materialName: name)
        dismiss()
    }
}
