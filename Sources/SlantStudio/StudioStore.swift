import SwiftUI
import UniformTypeIdentifiers
import AppKit

struct Record: Identifiable {
    let values: [String: Any]
    var id: String { string("publicFileServiceId", "publicId", "id", "name") }
    var name: String { string("name", "publicId", "publicFileServiceId", "id") }
    func string(_ keys: String...) -> String {
        for key in keys { if let value = values[key], !(value is NSNull) { return String(describing: value) } }
        return ""
    }
    var pretty: String { prettyJSON(values) }
    var metrics: [String: Any] { values["metrics"] as? [String: Any] ?? values["STLMetrics"] as? [String: Any] ?? [:] }
}

func prettyJSON(_ value: Any) -> String {
    guard JSONSerialization.isValidJSONObject(value), let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]), let text = String(data: data, encoding: .utf8) else { return String(describing: value) }
    return text
}
func responseRecords(_ response: APIResponse) -> [Record] {
    guard let root = response.json as? [String: Any] else { return [] }
    if let rows = root["data"] as? [[String: Any]] { return rows.map { Record(values: $0) } }
    if let data = root["data"] as? [String: Any] {
        for key in ["files", "orders", "platforms", "filaments", "components", "stationery", "items", "results", "webhooks"] {
            if let rows = data[key] as? [[String: Any]] { return rows.map { Record(values: $0) } }
        }
    }
    return []
}
func responseObject(_ response: APIResponse) -> [String: Any] {
    let root = response.json as? [String: Any] ?? [:]
    return root["data"] as? [String: Any] ?? root
}
func responsePagination(_ response: APIResponse) -> [String: Any]? {
    let root = response.json as? [String: Any] ?? [:]
    if let pagination = root["pagination"] as? [String: Any] { return pagination }
    if let data = root["data"] as? [String: Any], let pagination = data["pagination"] as? [String: Any] { return pagination }
    return nil
}
/// A whole, non-negative number from a pagination field: a JSON number or digits sent as text. Nil for booleans,
/// fractions and anything else, so an odd reply falls back to the page-size rule instead of being misread.
func paginationInteger(_ value: Any?) -> Int? {
    guard let value, !(value is NSNull) else { return nil }
    if let number = value as? NSNumber {
        guard CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let raw = number.doubleValue
        guard raw.isFinite, raw >= 0, raw == raw.rounded(), raw < 1e12 else { return nil }
        return number.intValue
    }
    if let text = value as? String, let parsed = Int(text.trimmingCharacters(in: .whitespacesAndNewlines)), parsed >= 0 {
        return parsed
    }
    return nil
}
/// Slant's `pagination.count`: the number of rows across every page of the list (live `GET /orders`, 28 Oct 2026).
func listPaginationTotalCount(_ pagination: [String: Any]?) -> Int? {
    paginationInteger(pagination?["count"])
}
/// Whether the list has a page after `currentPage`, decided from Slant's raw page (never from rows Studio trimmed).
/// An empty page is always the end, so Load More can never loop. Then `totalPages`; then `count` when it can only be a
/// total (more than the rows read so far means more remain; a count equal to a full page could also be a per-page
/// count, so that case falls through); otherwise a full page suggests more.
func listHasMorePages(pagination: [String: Any]?, recordCount: Int, currentPage: Int, pageSize: Int) -> Bool {
    guard recordCount > 0 else { return false }
    if let totalPages = paginationInteger(pagination?["totalPages"]) {
        return currentPage < totalPages
    }
    if let total = listPaginationTotalCount(pagination) {
        let limit = paginationInteger(pagination?["limit"]).flatMap { $0 > 0 ? $0 : nil } ?? pageSize
        let read = max(0, currentPage - 1) * limit + recordCount
        if total > read { return true }
        if total == read, recordCount < limit { return false }
    }
    return recordCount == pageSize
}
/// Whether a later page's `pagination.count` shows the list changed on Slant since page 1 was read (an order added,
/// or one leaving a status filter), so later pages may have shifted and skipped orders. Unknown counts never count.
func orderListChangedWhilePaging(firstCount: Int?, latestCount: Int?) -> Bool {
    guard let firstCount, let latestCount else { return false }
    return firstCount != latestCount
}
let orderListChangedWhileLoadingNote = "Orders changed on Slant while loading. Reload to see them all."

struct LocalModel: Codable, Identifiable {
    var id = UUID()
    var name: String
    var filePath: String
    var remoteID: String?
    var added = Date()
    var partIntent: PartIntent?
    var printRecipe: PreparedPrintRecipe?
    var designImprovement: DesignImprovementRecord?
    var reinforcement: ReinforcementRecord?
    var autoImprovement: AutoImprovementRecord?
    /// Designer, licence, source and copyright carried over from the 3MF (or earlier copy) an STL copy was made from.
    /// Nil for anything else; older libraries load without it (ModelSourceDetails.swift).
    var sourceDetails: ModelSourceDetails?
    /// On a print-ready copy: what the automatic preparation applied and skipped (PrintPreparation.swift).
    var printPreparation: PrintPreparationRecord?
    /// On an original: what the automatic preparation did with it, so it is explained and never repeated.
    var printPreparationStatus: PrintPreparationStatus?
    /// A further copy of a Z-up-locked model (such as a print-ready copy's repaired or auto-improved copy): it keeps the
    /// lock without claiming to be a print-ready copy itself. Nil for anything else; older libraries load without it.
    var inheritsZUpLock: Bool?
    /// Set on a saved replica, whose way up the seller chose in Which way is up?: preparation never re-places it.
    var keepsPlacement: Bool?
    /// Set on a Fill Hidden Pockets copy (HiddenPocketsView.swift): an edited copy for the licence advisory. Nil for
    /// anything else; older libraries load without it.
    var filledPockets: Bool?
    /// Set on any further copy of a print-ready copy (or of such a copy): it is already placed and prepared, and its
    /// saved purpose's load axes describe the original, so Make Print-Ready Copy is never run on it. Nil for anything
    /// else; older libraries load without it.
    var fromPrintReadyCopy: Bool?
    /// Set on a Make Fit Coupon piece (MeshFitView.swift), which is saved Z-up locked because it keeps the way up the
    /// full part prints: the lock's wording says so instead of naming layer-dependent features. Nil for anything else.
    var fitCoupon: Bool?
    var url: URL { URL(fileURLWithPath: filePath) }
    /// A print-ready copy, or a copy made from one.
    var derivesFromPrintReadyCopy: Bool { printPreparation != nil || fromPrintReadyCopy == true }
    /// Copies whose features depend on the print layers must stay Z up. A print-ready copy was placed on its bed face
    /// and may have slots opening through it, so it stays as placed, and so do its further copies.
    var requiresZUp: Bool {
        reinforcement?.requiresZUp == true || autoImprovement?.requiresZUp == true || printPreparation != nil
            || inheritsZUpLock == true
    }
    /// STL only: read by `STLMesh.read` and accepted by the orientation, edge, reinforcement and auto-improve tools.
    var supportsPreview: Bool { url.pathExtension.lowercased() == "stl" }
    /// STL, OBJ and 3MF: shown in the 3D preview with dimensions and the build-volume check.
    var supportsMeshPreview: Bool { ModelFileFormat(url: url) != nil }
}
/// What every further copy of `model` carries: its Z-up lock, a replica's chosen way up, and whether it derives from
/// a print-ready copy.
func studioCopyLineage(_ model: LocalModel) -> (inheritsZUpLock: Bool, keepsPlacement: Bool, fromPrintReadyCopy: Bool) {
    (model.requiresZUp, model.keepsPlacement == true, model.derivesFromPrintReadyCopy)
}

extension LocalModel {
    /// The identity and file are required; every record is read leniently, so one this build can't read (such as an
    /// orientation from a later version) drops only that record, never the model or the library.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        filePath = try c.decode(String.self, forKey: .filePath)
        added = try c.decode(Date.self, forKey: .added)
        // A placement or edit record that can't be read may have locked the copy Z up, so its loss keeps the lock.
        var lostRecord = false
        func record<T: Decodable>(_ type: T.Type, _ key: CodingKeys) -> T? {
            do { return try c.decodeIfPresent(type, forKey: key) } catch { lostRecord = true; return nil }
        }
        remoteID = try? c.decodeIfPresent(String.self, forKey: .remoteID)
        partIntent = try? c.decodeIfPresent(PartIntent.self, forKey: .partIntent)
        printRecipe = record(PreparedPrintRecipe.self, .printRecipe)
        designImprovement = record(DesignImprovementRecord.self, .designImprovement)
        reinforcement = record(ReinforcementRecord.self, .reinforcement)
        autoImprovement = record(AutoImprovementRecord.self, .autoImprovement)
        sourceDetails = try? c.decodeIfPresent(ModelSourceDetails.self, forKey: .sourceDetails)
        printPreparation = record(PrintPreparationRecord.self, .printPreparation)
        printPreparationStatus = try? c.decodeIfPresent(PrintPreparationStatus.self, forKey: .printPreparationStatus)
        inheritsZUpLock = try? c.decodeIfPresent(Bool.self, forKey: .inheritsZUpLock)
        if lostRecord { inheritsZUpLock = true }
        keepsPlacement = try? c.decodeIfPresent(Bool.self, forKey: .keepsPlacement)
        filledPockets = try? c.decodeIfPresent(Bool.self, forKey: .filledPockets)
        fromPrintReadyCopy = try? c.decodeIfPresent(Bool.self, forKey: .fromPrintReadyCopy)
        fitCoupon = try? c.decodeIfPresent(Bool.self, forKey: .fitCoupon)
    }
}
struct CloudDeleteRefusal: Identifiable, Equatable {
    let fileID: String
    let name: String
    let slantReason: String?
    var id: String { fileID }
}
func cloudDeleteRefusalMessage(_ refusal: CloudDeleteRefusal) -> String {
    var message = "Slant’s API only lets accounts with admin access delete files, even files you uploaded yourself."
    if let reason = refusal.slantReason { message += " Slant said: “\(reason)”." }
    message += " You can hide “\(refusal.name)” from your list instead; it stays in your Slant account."
    return message
}
func visibleCloudFiles(_ files: [Record], hidden: Set<String>, showHidden: Bool) -> [Record] {
    showHidden ? files : files.filter { !hidden.contains($0.id) }
}
func isManagedModelCopy(_ url: URL, supportDirectory: URL) -> Bool {
    let folder = supportDirectory.appendingPathComponent("Models", isDirectory: true)
        .standardizedFileURL.resolvingSymlinksInPath().path
    let path = url.standardizedFileURL.resolvingSymlinksInPath().path
    return path.hasPrefix(folder + "/")
}
struct Activity: Identifiable {
    let id = UUID()
    let date = Date()
    let title: String
    let detail: String
    let success: Bool
}
enum Destination: String, CaseIterable, Identifiable {
    case models = "Models", materials = "Materials", orders = "Orders", components = "Components", stationery = "Stationery", platforms = "Platforms", catalog = "Catalog", api = "API Workbench", activity = "Activity"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .models: "cube"
        case .materials: "paintpalette"
        case .orders: "shippingbox"
        case .components: "puzzlepiece.extension"
        case .stationery: "envelope"
        case .platforms: "storefront"
        case .catalog: "square.grid.2x2"
        case .api: "chevron.left.forwardslash.chevron.right"
        case .activity: "clock.arrow.circlepath"
        }
    }
    /// The kinds Catalog's picker shows. Platforms are managed in Settings › Account, not in Catalog.
    static let catalogKinds: [Destination] = [.materials, .components, .stationery]
    var isCatalogKind: Bool { Self.catalogKinds.contains(self) }
    /// API Workbench and Activity: listed only when Settings › Advanced › Show developer tools is on.
    var isDeveloperDestination: Bool { self == .api || self == .activity }
}

/// Tabs of the Settings window (⌘,), the single home for the account, platforms and developer options.
enum SettingsTab: Hashable {
    case account, designTools, advanced
}

let showDeveloperToolsDefaultsKey = "showDeveloperTools"

/// Where the main window goes when developer tools are switched on or off: hiding them moves a developer screen to
/// Models; anything else stays put.
func destinationAfterDeveloperToolsChange(_ destination: Destination, showDeveloperTools: Bool) -> Destination {
    (!showDeveloperTools && destination.isDeveloperDestination) ? .models : destination
}

/// Where a navigation request lands. Platforms open Settings instead (the screen stays put), and developer screens
/// can't be reached while developer tools are hidden. Catalog kinds land on Catalog.
func resolvedNavigation(requested: Destination, previous: Destination, showDeveloperTools: Bool) -> (destination: Destination, catalogKind: Destination?, opensSettings: Bool) {
    if requested == .platforms {
        return (previous == .platforms ? .models : previous, nil, true)
    }
    if requested.isDeveloperDestination, !showDeveloperTools {
        return (previous.isDeveloperDestination ? .models : previous, nil, false)
    }
    if requested.isCatalogKind { return (.catalog, requested, false) }
    return (requested, nil, false)
}

struct OrderFilter: Equatable {
    var status: String?
    var startDate: Date?
    var endDate: Date?
    var sortOrder: String = "desc"
    var isActive: Bool { status != nil || startDate != nil || endDate != nil }
}
/// Slant's order statuses since 26 Oct 2026 (live OpenAPI and docs; checked with read-only GETs on 28 Oct 2026, when
/// orders paid earlier read PRINTING). `GET /orders?status=` refuses any other value with 400 "Invalid status filter".
let orderLiveStatuses = ["DRAFT", "SUBMITTED", "PRINTING", "SHIPPED", "CANCELLED"]
/// The earlier status set. Slant no longer returns these, but Studio still recognises them in saved order-watch
/// snapshots and any old reply, with their earlier meaning. Never offer them as a filter: Slant refuses them.
let orderLegacyStatuses: Set<String> = [
    "PAID", "QUEUED", "PROCESSING", "ITEMS_ON_SHELF", "POST_PROCESSING", "COMPLETED", "IN_REVIEW",
    "AWAITING_SHIPMENT", "DELIVERED", "CANCELED", "PAYMENT_ERROR"
]
let orderKnownStatuses = Set(orderLiveStatuses).union(orderLegacyStatuses)
/// The toolbar Status menu offers exactly the values `GET /orders` accepts.
let orderStatusFilterOptions = orderLiveStatuses
/// CANCELLED (live) or CANCELED (the earlier spelling), in any case.
func orderStatusIsCancelled(_ status: String) -> Bool {
    let normalized = status.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    return normalized == "CANCELLED" || normalized == "CANCELED"
}
let maxPlatforms = 5
let listPageSize = 100

struct DeliveryDetails: Equatable {
    var email = ""
    var name = ""
    var line1 = ""
    var line2 = ""
    var city = ""
    var state = ""
    var zip = ""
    var countrySelection = defaultDeliveryCountry().selection
    var customCountry = defaultDeliveryCountry().customCode
}

enum OutcomeAction: Equatable {
    case pay, cancel
}
/// What was attempted when an order's outcome became unknown, so another sheet can tell when a reload resolves it.
struct UnknownOutcomeContext: Equatable {
    var action: OutcomeAction
    var reviewedStatus: String
}
/// The session's pay/cancel lock: locked order IDs, what was attempted for each, and IDs that name the same order.
/// Marking with aliases locks every ID of the group; clearing any ID of a group clears the whole group. Memory only.
struct OrderOutcomeLocks: Equatable {
    private(set) var ids: Set<String> = []
    private(set) var contexts: [String: UnknownOutcomeContext] = [:]
    private var aliases: [String: Set<String>] = [:]

    mutating func mark(_ orderID: String, action: OutcomeAction?, reviewedStatus: String?, aliases extra: [String] = []) {
        let id = orderID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { return }
        var group: Set<String> = [id]
        for alias in extra {
            let trimmed = alias.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { group.insert(trimmed) }
        }
        // Join any group a member already belongs to, so one lift still clears every ID of the order.
        for member in group { group.formUnion(aliases[member] ?? []) }
        for member in group {
            ids.insert(member)
            if let action {
                contexts[member] = UnknownOutcomeContext(action: action, reviewedStatus: (reviewedStatus ?? "").uppercased())
            } else {
                contexts[member] = nil
            }
            aliases[member] = group.count > 1 ? group : nil
        }
    }

    mutating func clear(_ orderID: String) {
        let id = orderID.trimmingCharacters(in: .whitespacesAndNewlines)
        for member in (aliases[id] ?? []).union([id, orderID]) {
            ids.remove(member)
            contexts[member] = nil
            aliases[member] = nil
        }
    }

    /// Each locked order once: a group of aliases, or a single ID.
    var groups: [Set<String>] {
        var seen = Set<String>()
        var result: [Set<String>] = []
        for id in ids.sorted() where !seen.contains(id) {
            let group = aliases[id] ?? [id]
            seen.formUnion(group)
            result.append(group)
        }
        return result
    }
}

struct WebhookTestResult: Equatable {
    var attempted: Bool
    var endpointStatus: Int?
    var message: String?
}
struct WebhookResendResult: Equatable {
    var attempted: Int
    var delivered: Int
    var failed: Int
    var expired: Int
    var remaining: Int
}
struct WebhookSingleResendResult: Equatable {
    var success: Bool
    var status: Int?
    var error: String?
    var alreadyDelivered: Bool
    var expired: Bool
}

/// The Mac's calendar days, as the Orders date filter's From and To mean them.
func orderFilterCalendar(timeZone: TimeZone = .current) -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = timeZone
    return calendar
}
func orderFilterDateString(_ date: Date, timeZone: TimeZone = .current) -> String {
    let formatter = DateFormatter()
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = timeZone
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter.string(from: date)
}
/// Slant reads `startDate`/`endDate` as dates without saying in which time zone, so the list asks for a day's margin
/// either side (as the Spending Report does) and `orderFilterTrimmed` keeps only orders created on the chosen days in
/// the Mac's calendar. `startDate` is the day before From.
func orderFilterStartDateQueryValue(_ startDate: Date, timeZone: TimeZone = .current) -> String {
    let calendar = orderFilterCalendar(timeZone: timeZone)
    let start = calendar.startOfDay(for: startDate)
    return orderFilterDateString(calendar.date(byAdding: .day, value: -1, to: start) ?? start, timeZone: timeZone)
}
/// `endDate` means “created before this date”: the day after To includes that day, and one more day is the margin.
func orderFilterEndDateQueryValue(_ endDate: Date, timeZone: TimeZone = .current) -> String {
    let calendar = orderFilterCalendar(timeZone: timeZone)
    let start = calendar.startOfDay(for: endDate)
    return orderFilterDateString(calendar.date(byAdding: .day, value: 2, to: start) ?? start, timeZone: timeZone)
}
/// The filter's dates as an interval in the Mac's calendar: from the start of From to the end of To (nil: unbounded).
func orderFilterLocalInterval(_ filter: OrderFilter, timeZone: TimeZone = .current) -> (start: Date?, end: Date?) {
    let calendar = orderFilterCalendar(timeZone: timeZone)
    let start = filter.startDate.map { calendar.startOfDay(for: $0) }
    let end = filter.endDate.map { date -> Date in
        let day = calendar.startOfDay(for: date)
        return calendar.date(byAdding: .day, value: 1, to: day) ?? day
    }
    return (start, end)
}
/// The rows of a date-filtered page that were created on the chosen days in the Mac's calendar; the margin days Slant
/// returned are dropped. Rows without a readable creation date are kept (they can't be judged), and without dates the
/// page is returned unchanged. Has-more is still decided from the raw page.
func orderFilterTrimmed(_ records: [Record], filter: OrderFilter, timeZone: TimeZone = .current) -> [Record] {
    let interval = orderFilterLocalInterval(filter, timeZone: timeZone)
    guard interval.start != nil || interval.end != nil else { return records }
    return records.filter { record in
        guard let created = orderCreatedDate(orderObject(record.values)) else { return true }
        if let start = interval.start, created < start { return false }
        if let end = interval.end, created >= end { return false }
        return true
    }
}
func normalizedOrderSortOrder(_ sortOrder: String) -> String {
    sortOrder.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() == "ASC" ? "ASC" : "DESC"
}
func orderFilterValidationError(_ filter: OrderFilter) -> String? {
    if let start = filter.startDate, let end = filter.endDate, start > end {
        return "Start date must be on or before end date."
    }
    return nil
}
func orderFilterQueryItems(_ filter: OrderFilter, page: Int, limit: Int, platformID: String) -> [String: String] {
    var query = ["page": String(page), "limit": String(limit), "sortBy": "createdAt", "sortOrder": normalizedOrderSortOrder(filter.sortOrder)]
    if !platformID.isEmpty { query["platformId"] = platformID }
    if let status = filter.status, !status.isEmpty { query["status"] = status }
    if let start = filter.startDate { query["startDate"] = orderFilterStartDateQueryValue(start) }
    if let end = filter.endDate { query["endDate"] = orderFilterEndDateQueryValue(end) }
    return query
}
/// Whether a reload in the Orders review sheet clears a shared lock. Without a record of what was attempted, or a cancel
/// without the status it was sent from, the reload can't show whether the request took effect, so the lock stays.
func unknownOutcomeResolvedByReload(context: UnknownOutcomeContext?, reloadedStatus: String) -> Bool {
    let reloaded = reloadedStatus.uppercased()
    guard !reloaded.isEmpty, let context else { return false }
    if context.action == .cancel, context.reviewedStatus.isEmpty { return false }
    return outcomeResolved(action: context.action, reviewedStatus: context.reviewedStatus, reloadedStatus: reloaded)
}
/// A pay/cancel error that shows Slant did not act: the request failed before it was sent, or Slant refused it with a
/// definite client error. Timeouts, transport failures, 5xx, 408 and 409 leave the outcome unknown. `method` matters
/// only for URL errors: URLSession may resend an idempotent DELETE on a fresh connection after a reused one drops, so a
/// DNS failure on that resend wouldn't prove the first attempt never reached Slant.
func orderMutationErrorProvesNoEffect(_ error: Error, method: String = "POST") -> Bool {
    if let urlError = error as? URLError { return orderMutationURLErrorIsBeforeSending(urlError.code, method: method) }
    switch error as? APIError {
    case .invalidRequest?: return true
    case .http(let status, _, _, _)?: return (400..<500).contains(status) && status != 408 && status != 409
    default: return false
    }
}
/// URL failures that happen before any of the request leaves the Mac: Slant's host name couldn't be resolved, or the
/// URL was refused locally. Every other failure (no connection, a connection refused or lost, a timeout, a cancel, TLS
/// and the rest) may have reached Slant, so it leaves the outcome unknown.
func orderMutationURLErrorIsBeforeSending(_ code: URLError.Code, method: String = "POST") -> Bool {
    switch code {
    case .badURL, .unsupportedURL, .appTransportSecurityRequiresSecureConnection:
        return true
    case .cannotFindHost, .dnsLookupFailed:
        return method.uppercased() != "DELETE"
    default:
        return false
    }
}
/// The IDs one pay/cancel lock is kept under: the ID the request was sent for, plus the `publicId` and `id` of the
/// order Slant returned for it when they differ (the API Workbench takes a typed ID, which may not be the one Orders
/// lists). Lifting the lock under any of them lifts it under all (`StudioStore.markOutcomeUnknown(aliases:)`).
func orderOutcomeLockIDs(requested: String, order: [String: Any]?) -> [String] {
    var ids: [String] = []
    for candidate in [requested, order?["publicId"] as? String, order?["id"] as? String] {
        let trimmed = (candidate ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty, !ids.contains(trimmed) { ids.append(trimmed) }
    }
    return ids
}
func outcomeResolved(action: OutcomeAction, reviewedStatus: String, reloadedStatus: String) -> Bool {
    switch action {
    case .pay: return reloadedStatus != "DRAFT"
    case .cancel: return reloadedStatus != reviewedStatus
    }
}
/// Shared copy when pay/cancel was sent but the order status hasn’t been reloaded yet.
let unknownOutcomeBlockMessage = "This order’s last payment or cancel request didn’t confirm. Reload the order; if its status hasn’t changed, check it in your Slant dashboard before trying again."
/// Only refresh after connect when this attempt succeeded (never refresh on a failed key change).
func shouldRefreshAfterConnect(succeeded: Bool) -> Bool { succeeded }
func extractedWebhookSecret(from object: [String: Any]) -> String? {
    for key in ["webhookSecret", "secret"] {
        if let value = object[key] as? String {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
    }
    return nil
}
func parseWebhookTestResult(from data: [String: Any]) -> WebhookTestResult {
    let attempted: Bool
    if let flag = data["success"] as? Bool { attempted = flag }
    else if let number = data["success"] as? NSNumber { attempted = number.boolValue }
    else { attempted = false }
    var endpointStatus: Int?
    var responseError: String?
    if let response = data["response"] as? [String: Any] {
        endpointStatus = response["status"] as? Int ?? (response["status"] as? NSNumber)?.intValue
        responseError = response["error"] as? String
    }
    let message = (data["message"] as? String) ?? responseError
    return WebhookTestResult(attempted: attempted, endpointStatus: endpointStatus, message: message)
}
func parseWebhookResendResult(from data: [String: Any]) -> WebhookResendResult {
    func intValue(_ key: String) -> Int {
        if let value = data[key] as? Int { return value }
        if let number = data[key] as? NSNumber { return number.intValue }
        return 0
    }
    return WebhookResendResult(
        attempted: intValue("attempted"),
        delivered: intValue("delivered"),
        failed: intValue("failed"),
        expired: intValue("expired"),
        remaining: intValue("remaining")
    )
}
func parseWebhookSingleResendResult(from data: [String: Any]) -> WebhookSingleResendResult {
    let success: Bool
    if let flag = data["success"] as? Bool { success = flag }
    else if let number = data["success"] as? NSNumber { success = number.boolValue }
    else { success = false }
    let status = data["status"] as? Int ?? (data["status"] as? NSNumber)?.intValue
    let already: Bool
    if let flag = data["alreadyDelivered"] as? Bool { already = flag }
    else if let number = data["alreadyDelivered"] as? NSNumber { already = number.boolValue }
    else { already = false }
    let expired: Bool
    if let flag = data["expired"] as? Bool { expired = flag }
    else if let number = data["expired"] as? NSNumber { expired = number.boolValue }
    else { expired = false }
    return WebhookSingleResendResult(
        success: success,
        status: status,
        error: data["error"] as? String,
        alreadyDelivered: already,
        expired: expired
    )
}
func importModelType(url: String, name: String) -> String {
    let urlExt = URL(string: url)?.pathExtension ?? ""
    let nameExt = (name as NSString).pathExtension
    let ext = urlExt.isEmpty ? nameExt : urlExt
    return uploadTypeParameter(forFileExtension: ext) ?? "stl"
}
func componentCategoryName(id: String, in categories: [Record]) -> String? {
    guard !id.isEmpty else { return nil }
    var parts: [String] = []
    var current: String? = id
    var guardCount = 0
    while let cid = current, !cid.isEmpty, guardCount < 32 {
        guard let record = categories.first(where: { $0.id == cid }) else { break }
        let name = record.string("name")
        if !name.isEmpty { parts.insert(name, at: 0) }
        let parent = record.string("parentId", "parentID")
        current = parent.isEmpty ? nil : parent
        guardCount += 1
    }
    return parts.isEmpty ? nil : parts.joined(separator: " › ")
}
func isSecretLikeUsageKey(_ key: String) -> Bool {
    let lower = key.lowercased()
    return lower.contains("secret") || lower.contains("token") || lower.contains("password")
        || lower == "key" || lower.hasSuffix("key") || lower.contains("apikey") || lower.contains("api_key")
}
/// Sentence case for an API field name ("totalCurrentUsage" → "Total current usage"); acronyms such as API stay.
func humanizeUsageLabel(_ key: String) -> String {
    let spaced = key.replacingOccurrences(of: "_", with: " ")
        .replacingOccurrences(of: "([a-z])([A-Z])", with: "$1 $2", options: .regularExpression)
        .replacingOccurrences(of: "([A-Z]+)([A-Z][a-z])", with: "$1 $2", options: .regularExpression)
    let words = spaced.split(separator: " ").enumerated().map { index, word -> String in
        let text = String(word)
        if text.count > 1, text == text.uppercased() { return text }
        return index == 0 ? text.prefix(1).uppercased() + text.dropFirst() : text.lowercased()
    }
    return words.joined(separator: " ")
}
func usageScalarRows(from object: [String: Any], prefix: String = "") -> [(String, String)] {
    var rows: [(String, String)] = []
    for (key, value) in object.sorted(by: { $0.key < $1.key }) {
        if isSecretLikeUsageKey(key) { continue }
        if value is NSNull { continue }
        if value is [Any] || value is [String: Any] { continue }
        let label = prefix.isEmpty ? humanizeUsageLabel(key) : "\(prefix) · \(humanizeUsageLabel(key))"
        let text = String(describing: value)
        rows.append((label, key.lowercased().contains("percent") && value is NSNumber ? text + "%" : text))
    }
    return rows
}

/// The order number to look up for a typed search: Slant's IDs are upper case, and a bare number gets the SLANT_
/// prefix, so "slant_123" and "123" both find SLANT_123.
func orderSearchPublicID(_ typed: String) -> String {
    let trimmed = typed.trimmingCharacters(in: .whitespacesAndNewlines)
    if !trimmed.isEmpty, trimmed.allSatisfy(\.isASCII), trimmed.allSatisfy(\.isNumber) { return "SLANT_" + trimmed }
    return trimmed.uppercased()
}
/// Slant's answer for an order that doesn't exist: 404, or the 400 "Order not found." live `GET /orders/{id}` gives
/// (seen 23 and 28 Oct 2026). Any other 400 is a real refusal and isn't treated as not found.
func orderNotFoundStatus(_ status: Int, body: String = "") -> Bool {
    if status == 404 { return true }
    guard status == 400, let message = shortAPIMessage(from: body) else { return false }
    return message.lowercased().contains("order not found")
}
func orderNotFoundError(_ error: Error) -> Bool {
    guard case .http(let status, let body, _, _)? = error as? APIError else { return false }
    return orderNotFoundStatus(status, body: body)
}
/// Return in the Orders search box: `GET /orders?publicId=` for the typed order number. `/orders/search` isn't used:
/// Slant routes it as an order lookup (every query gets 400 "Order not found.", seen 23 and 28 Oct 2026).
func orderSearchQueryItems(_ typed: String, platformID: String) -> [String: String] {
    var query = ["publicId": orderSearchPublicID(typed), "limit": String(listPageSize), "page": "1"]
    let platform = platformID.trimmingCharacters(in: .whitespacesAndNewlines)
    if !platform.isEmpty { query["platformId"] = platform }
    return query
}
/// Only rows whose order number is the one looked up (ignoring case), so a reply that ignored `publicId` (the newest
/// orders) is never shown as search results.
func orderSearchMatchingRecords(_ records: [Record], typed: String) -> [Record] {
    let wanted = orderSearchPublicID(typed)
    guard !wanted.isEmpty else { return [] }
    return records.filter { record in
        guard let publicID = orderObject(record.values)["publicId"] as? String else { return false }
        return publicID.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare(wanted) == .orderedSame
    }
}

func filamentAvailability(_ record: Record) -> Bool? {
    guard let value = record.values["available"], !(value is NSNull) else { return nil }
    if let flag = value as? Bool { return flag }
    if let number = value as? NSNumber { return number.boolValue }
    return nil
}
func filamentAvailabilityLabel(_ record: Record) -> String? {
    filamentAvailability(record) == false ? "Out of stock" : nil
}
let otherFilamentType = "Other"

/// Material type from the live `profile` field, so new types Slant adds appear without an app update.
func filamentType(_ record: Record) -> String {
    let profile = record.string("profile").trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    return profile.isEmpty ? otherFilamentType : profile
}

func filamentTypes(in filaments: [Record]) -> [String] {
    Set(filaments.map(filamentType)).sorted { lhs, rhs in
        if (lhs == otherFilamentType) != (rhs == otherFilamentType) { return rhs == otherFilamentType }
        return lhs < rhs
    }
}

func filamentsMatching(_ filaments: [Record], type: String?) -> [Record] {
    guard let type else { return filaments }
    return filaments.filter { filamentType($0) == type }
}

/// Material to use after the type filter changes: keeps the current choice when it already matches,
/// otherwise the first in-stock material of that type.
func filamentIDAfterTypeChange(currentID: String, type: String?, filaments: [Record]) -> String {
    guard let type else { return currentID }
    let matching = filamentsMatching(filaments, type: type)
    if matching.contains(where: { $0.id == currentID }) { return currentID }
    return (matching.first { filamentAvailability($0) != false } ?? matching.first)?.id ?? currentID
}

func plaBlackFilamentID(in filaments: [Record]) -> String? {
    let available = filaments.filter { filamentAvailability($0) != false }
    if let exact = available.first(where: { $0.name.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare("PLA BLACK") == .orderedSame }) {
        return exact.id
    }
    return available.first { filament in
        let name = filament.name.lowercased()
        return name.contains("pla") && name.contains("black")
    }?.id
}

@MainActor final class StudioStore: ObservableObject {
    /// Opens on the last sidebar section (StudioView.swift saves it).
    @Published var destination: Destination = restoredSidebarDestination(
        saved: UserDefaults.standard.string(forKey: lastSidebarDestinationDefaultsKey),
        showDeveloperTools: UserDefaults.standard.bool(forKey: showDeveloperToolsDefaultsKey)) {
        didSet { redirectDestinationIfNeeded(from: oldValue) }
    }
    @Published var catalogKind: Destination = .materials {
        didSet {
            // Platforms moved to Settings › Account; Catalog only shows materials, components and stationery.
            guard !catalogKind.isCatalogKind else { return }
            let requested = catalogKind
            catalogKind = oldValue.isCatalogKind ? oldValue : .materials
            if requested == .platforms { requestSettings(.account) }
        }
    }
    /// Settings › Advanced › Show developer tools (off by default). It only changes what the sidebar and Go menu list:
    /// Activity keeps recording and no lock, request or safeguard is touched. Settings refuses the change while a
    /// request runs or anything modal is shown, so a Workbench review or request is never torn down part-way.
    @Published var showDeveloperTools = UserDefaults.standard.bool(forKey: showDeveloperToolsDefaultsKey) {
        didSet {
            UserDefaults.standard.set(showDeveloperTools, forKey: showDeveloperToolsDefaultsKey)
            let next = destinationAfterDeveloperToolsChange(destination, showDeveloperTools: showDeveloperTools)
            if next != destination { destination = next }
        }
    }
    /// The Settings tab to show; set by `requestSettings(_:)` and by the Settings window itself.
    @Published var settingsTab: SettingsTab = .account
    /// Bumped to ask the main window to open the Settings window (the window owns the `openSettings` action).
    @Published private(set) var settingsOpenRequest = 0
    @Published var apiKey = ""
    @Published var platformID = UserDefaults.standard.string(forKey: "platformID") ?? "" { didSet { UserDefaults.standard.set(platformID, forKey: "platformID") } }
    @Published var ownerID = UserDefaults.standard.string(forKey: "ownerID") ?? "" { didSet { UserDefaults.standard.set(ownerID, forKey: "ownerID") } }
    @Published var busy = false
    @Published var progress = ""
    @Published var error: String?
    @Published var connected = false
    @Published var localModels: [LocalModel] = []
    /// Saved products (SavedProducts.swift). References only; persisted to products.json.
    @Published var savedProducts: [SavedProduct] = []
    @Published var showSavedProducts = false
    /// A new product for the Saved Products editor (Models › Save as Product…); consumed when the sheet opens.
    @Published var pendingSavedProductDraft: SavedProduct?
    /// The seller's own address (SellerAddress.swift): opt-in, saved to seller-address.json, removable in Settings.
    @Published var sellerAddress: SellerAddress?
    /// Order a Sample to Me… without a saved address: the main window explains and offers Settings.
    @Published var showSellerAddressNeeded = false
    @Published var selectedLocalID: UUID?
    /// Automatic preparation of new STL models for printing (PrintPreparation.swift).
    let printPreparationQueue = PrintPreparationQueue()
    /// Fill Hidden Pockets, the seller's own request (HiddenPocketsView.swift).
    let hiddenPocketsFill = HiddenPocketsFillRun()
    @Published var files: [Record] = []
    @Published var platforms: [Record] = []
    @Published var filaments: [Record] = []
    private(set) var filamentsLoadedAt: Date?
    private var filamentsRefreshing = false
    @Published var orders: [Record] = []
    @Published var components: [Record] = []
    @Published var stationery: [Record] = []
    @Published var activities: [Activity] = []
    @Published var fileID = ""
    @Published var filamentID = ""
    @Published var quantity = 1
    @Published var estimate: [String: Any]?
    @Published var estimateContext = ""
    @Published var draft: [String: Any]?
    @Published var showOrderComposer = false
    @Published var pendingOrderPrefill: OrderComposerPrefill?
    /// Create Platform sheet in the main window (for example from the Models next-action bar). Only one window shows
    /// the composer at a time: while Settings has its own open, this request brings Settings forward instead.
    @Published var showPlatformComposer = false {
        didSet {
            if showPlatformComposer, showSettingsPlatformComposer {
                showPlatformComposer = false
                requestSettings(.account)
            }
        }
    }
    /// Create Platform sheet in the Settings window (Account tab). Counted in `isPresentingSheet`.
    @Published var showSettingsPlatformComposer = false
    @Published var showImportFromURL = false
    /// Import Orders sheet (OrderImport.swift).
    @Published var showOrderImport = false
    /// Pay Several Drafts sheet (BatchPay.swift), presented by Orders. Counted in `isPresentingSheet`.
    @Published var batchPayRequest: BatchPayRequest?
    /// Listing assets and spending report sheets (ListingAssets.swift, SpendReport.swift). Counted in `isPresentingSheet`.
    @Published var listingImagesModelID: UUID?
    @Published var showSpendingReport = false
    /// Personalise from Template sheet (Personalisation.swift): the chosen .scad file, in memory only.
    @Published var personalisationTemplate: PersonalisationTemplateFile?
    /// Scale to Size, Add Flat Base and Add Plinth sheets (MeshFitView.swift). Counted in `isPresentingSheet`.
    @Published var meshFitRequest: MeshFitRequest?
    /// Review for Printing with Claude (PrintReviewView.swift).
    @Published var printReviewRequest: PrintReviewRequest?
    /// Generate a Replica from an Image (ReplicaGeneratorView.swift). Counted in `isPresentingSheet`.
    @Published var showReplicaGenerator = false
    /// A review asked for from the replica sheet, opened once that sheet has closed (`presentPendingPrintReview`).
    var pendingPrintReview: PrintReviewRequest?
    /// Design an Accessory from a Photo (AccessoryDesignerView.swift). Its photos and conversation live in the sheet.
    @Published var showAccessoryDesigner = false
    /// Source orders imported this session (OrderImport.swift). Memory only; cleared when the account changes.
    @Published var orderImportLedger = OrderImportLedger()
    /// What buyers paid for drafts Import Orders created, by Slant order ID (ImportedSaleAmounts.swift): memory only,
    /// for the Profit check and the pay review. Never saved, logged or in Activity; dropped on Disconnect or a key change.
    @Published var importedSaleAmounts: [String: ImportedSaleAmounts] = [:]
    /// Tracking for Your Shop sheet (OrderFollowUp.swift). Counted in `isPresentingSheet`.
    @Published var showShopFollowUp = false
    /// Orders ticked "done in shop" in that sheet: order IDs in memory only, for this session.
    @Published var shopFollowUpDoneIDs: Set<String> = []
    @Published var accountLoaded = false
    @Published var filesLoaded = false
    @Published var ordersLoaded = false
    @Published var loadedCatalogs: Set<Destination> = []
    @Published var filePage = 0
    @Published var orderPage = 0
    @Published private(set) var filesHasMore = false
    @Published private(set) var ordersHasMore = false
    /// Load More saw Slant's `pagination.count` differ from page 1's: orders were added or left the filter while the
    /// pages loaded, so some may have been skipped. Cleared by the next reload, search or filter.
    @Published private(set) var ordersChangedWhileLoading = false
    /// Page 1's `pagination.count` for the loaded order list (nil when Slant didn't send one).
    private var ordersFirstPageCount: Int?
    /// Bumped by File › Export Orders…; the Orders screen exports the rows its list shows (after search and sort).
    @Published var ordersExportRequest = 0
    @Published private(set) var orderSearchActive = false
    @Published private(set) var fileSearchActive = false
    @Published var orderFilter = OrderFilter()
    @Published var selectedEndpointID: String?
    @Published var canRetry = false
    @Published var rateLimit: RateLimitInfo?
    @Published var usage: [String: Any]?
    @Published var healthStatus: [String: Any]?
    @Published var lastDelivery: DeliveryDetails?
    @Published var disabledPlatformsThisSession: [Record] = []
    @Published var deadWebhooks: [String: [Record]] = [:]
    /// Local models whose last upload failed after `confirm-upload` was sent without a clear answer, so Slant may hold
    /// the file. Memory only; Models suggests Refresh before uploading again (`uploadUnconfirmedMessage`).
    @Published var unconfirmedUploadModelIDs: Set<UUID> = []
    @Published var componentCategories: [Record] = []
    @Published var hiddenFileIDs = Set(UserDefaults.standard.stringArray(forKey: "hiddenFileIDs") ?? []) {
        didSet { UserDefaults.standard.set(hiddenFileIDs.sorted(), forKey: "hiddenFileIDs") }
    }
    @Published var cloudDeleteRefusal: CloudDeleteRefusal?
    /// Slant files deleted this session, so restoring a removed library entry never relinks to one.
    private(set) var deletedCloudFileIDs: Set<String> = []
    @Published private(set) var unknownOutcomeOrderIDs: Set<String> = []
    /// Earlier Create Draft attempts that didn’t confirm, so Slant may hold those drafts (recipient name and time, in
    /// memory only). Every composer shows a notice while any is listed, and asks for "Create Anyway" when the draft
    /// could repeat one (`draftCreateNeedsCreateAnyway`). An attempt is removed only by a confirmed creation for the
    /// same recipient name, or by Look for Draft on Slant finding its marker.
    /// See `unconfirmedDraftAttempts(previous:attempt:recipient:date:)`.
    @Published var unconfirmedDraftCreates: [UnconfirmedDraftAttempt] = []
    /// Older unconfirmed attempts dropped off that list (it keeps the latest 5): their recipients are unknown, so the
    /// guard stays on for the rest of the session (`unconfirmedDraftAttemptsOverflowed`).
    @Published var unconfirmedDraftCreatesOverflowed = false
    var draftCreateOutcomeUnknown: Bool { !unconfirmedDraftCreates.isEmpty || unconfirmedDraftCreatesOverflowed }
    /// The pay/cancel lock's IDs, contexts and aliases; `unknownOutcomeOrderIDs` mirrors its IDs for observers.
    private var outcomeLocks = OrderOutcomeLocks()
    // MARK: Model library actions (see ModelLibraryActions.swift)
    /// Local model whose rename sheet is open; set from the context menu, inspector or Model menu.
    @Published var renamingModelID: UUID?
    // MARK: -
    let endpoints = EndpointCatalog.load()
    private var cachedClientKey = ""
    private var cachedClient: APIClient?
    private var connectGeneration = 0
    var client: APIClient {
        let key = apiKey
        if let cached = cachedClient, cachedClientKey == key { return cached }
        cachedClient?.invalidate()
        let created = APIClient(apiKey: key)
        cachedClient = created
        cachedClientKey = key
        return created
    }
    var selectedLocal: LocalModel? { localModels.first { $0.id == selectedLocalID } }
    var hasKey: Bool { !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var estimateIsCurrent: Bool { estimateContext == "\(fileID)|\(filamentID)|\(quantity)" }
    var defaultFilamentID: String? { plaBlackFilamentID(in: filaments) }
    var platformLimitReached: Bool { platforms.count >= maxPlatforms }
    var orderDraftBlockedReason: String? {
        orderDraftBlockedReasonText(hasKey: hasKey, platformID: platformID)
    }
    var importFromURLBlockedReason: String? {
        if !hasKey { return "Connect your account first." }
        if platformID.isEmpty { return "Choose a default platform in Settings › Account." }
        if busy { return "Working…" }
        return nil
    }
    private var pendingRetry: RetryAction?
    private struct ConnectSuperseded: Error {}
    enum RetryAction {
        case connect(String)
        case refresh
        case loadMoreFiles
        case searchOrders(String)
        case loadMoreOrders
        case loadCatalog(Destination)
        case quote
        case loadUsage
        case loadHealth
        case loadDeadWebhooks(String)
        case applyOrderFilter
        case loadPlatform(String)
        case loadComponentCategories
    }
    static var supportDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("SlantStudio")
    }
    init() {
        do { apiKey = try KeychainStore.load() } catch {
            // With no key loaded, the main window shows its Connect Slant Account prompt.
            showError("Slant Studio couldn’t read the saved key. Enter it again in Settings.")
        }
        let path = Self.supportDirectory.appendingPathComponent("models.json")
        if let data = try? Data(contentsOf: path), let saved = try? JSONDecoder().decode([LocalModel].self, from: data) { localModels = saved }
        savedProducts = loadSavedProducts(from: Self.supportDirectory.appendingPathComponent(savedProductsFileName))
        sellerAddress = loadSellerAddress(from: Self.sellerAddressURL)
        // Personalisation hook (Personalisation.swift): remove leftover OpenSCAD temp folders; stop local runs on quit.
        PersonalisationTempCleanup.startAtLaunch()
        printPreparationQueue.store = self
    }
    private func redirectDestinationIfNeeded(from oldValue: Destination) {
        let resolved = resolvedNavigation(requested: destination, previous: oldValue, showDeveloperTools: showDeveloperTools)
        if let kind = resolved.catalogKind { catalogKind = kind }
        if resolved.destination != destination { destination = resolved.destination }
        if resolved.opensSettings { requestSettings(.account) }
    }
    /// Asks the main window to open the Settings window on `tab`. Opening Settings never changes the main window.
    func requestSettings(_ tab: SettingsTab = .account) {
        settingsTab = tab
        settingsOpenRequest += 1
    }
    private func noteRateLimit(from response: APIResponse) {
        // Public endpoints such as /health/status send no rate-limit headers; keep the last known allowance.
        if response.rateLimit.hasValues { rateLimit = response.rateLimit }
        // A kept allowance whose reset time has passed no longer says anything; drop it rather than show stale counts.
        else if let reset = rateLimit?.reset, reset <= Date() { rateLimit = nil }
    }
    // MARK: Order watch hook (OrderWatch.swift)
    /// Background order checks report the allowance they used, so the next check and Settings see it.
    func noteBackgroundRateLimit(from response: APIResponse) { noteRateLimit(from: response) }
    // MARK: -
    func saveModels() {
        do {
            try FileManager.default.createDirectory(at: Self.supportDirectory, withIntermediateDirectories: true)
            try JSONEncoder().encode(localModels).write(to: Self.supportDirectory.appendingPathComponent("models.json"), options: .atomic)
        } catch { showError("Could not save library: \(error.localizedDescription)") }
    }
    func importModel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = ["stl", "obj", "3mf"].compactMap { UTType(filenameExtension: $0) }
        panel.allowsMultipleSelection = true
        if panel.runModal() == .OK { for url in panel.urls { importModel(url, origin: .imported) } }
    }
    func savePartIntent(_ intent: PartIntent, modelID: UUID) {
        guard let index = localModels.firstIndex(where: { $0.id == modelID }) else { return }
        localModels[index].partIntent = intent
        saveModels()
    }
    /// Copies a model file into the library. `origin` says where it came from, which decides whether Studio also makes
    /// a print-ready copy of it (`ModelImportOrigin.mayPrepareForPrinting`); every caller states it.
    @discardableResult
    func importModel(_ url: URL, recipe: PreparedPrintRecipe? = nil, improvement: DesignImprovementRecord? = nil, intent: PartIntent? = nil, reinforcement: ReinforcementRecord? = nil, autoImprovement: AutoImprovementRecord? = nil, sourceDetails: ModelSourceDetails? = nil, printPreparation: PrintPreparationRecord? = nil, inheritsZUpLock: Bool = false, origin: ModelImportOrigin, keepsPlacement: Bool = false, fromPrintReadyCopy: Bool = false) -> Bool {
        importModelReturningID(url, recipe: recipe, improvement: improvement, intent: intent, reinforcement: reinforcement,
                               autoImprovement: autoImprovement, sourceDetails: sourceDetails, printPreparation: printPreparation,
                               inheritsZUpLock: inheritsZUpLock,
                               origin: origin, keepsPlacement: keepsPlacement, fromPrintReadyCopy: fromPrintReadyCopy) != nil
    }
    /// `importModel`, returning the new model's ID. `selectsAndShows: false` adds it without changing the selection
    /// or the screen, for copies saved in the background; `insertingBefore` places it next to that model (else first).
    /// `keepsPlacement` carries a replica's chosen way up to a further copy; `filledPockets` marks a Fill Hidden Pockets
    /// copy.
    @discardableResult
    func importModelReturningID(_ url: URL, recipe: PreparedPrintRecipe? = nil, improvement: DesignImprovementRecord? = nil, intent: PartIntent? = nil, reinforcement: ReinforcementRecord? = nil, autoImprovement: AutoImprovementRecord? = nil, sourceDetails: ModelSourceDetails? = nil, printPreparation: PrintPreparationRecord? = nil, inheritsZUpLock: Bool = false, origin: ModelImportOrigin, selectsAndShows: Bool = true, insertingBefore neighbour: UUID? = nil, keepsPlacement: Bool = false, filledPockets: Bool = false, fromPrintReadyCopy: Bool = false, fitCoupon: Bool = false) -> UUID? {
        let ext = url.pathExtension.lowercased()
        guard ["stl", "obj", "3mf"].contains(ext) else {
            showError("Slant Studio accepts STL, OBJ, and 3MF models.")
            return nil
        }
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        do {
            let folder = Self.supportDirectory.appendingPathComponent("Models")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let destination = folder.appendingPathComponent(UUID().uuidString + "." + ext)
            try FileManager.default.copyItem(at: url, to: destination)
            let model = LocalModel(name: url.deletingPathExtension().lastPathComponent, filePath: destination.path,
                                   partIntent: recipe?.intent ?? intent, printRecipe: recipe, designImprovement: improvement, reinforcement: reinforcement, autoImprovement: autoImprovement,
                                   sourceDetails: sourceDetails?.isEmpty == false ? sourceDetails : nil,
                                   printPreparation: printPreparation, inheritsZUpLock: inheritsZUpLock ? true : nil,
                                   keepsPlacement: origin == .replica || keepsPlacement ? true : nil,
                                   filledPockets: filledPockets ? true : nil, fromPrintReadyCopy: fromPrintReadyCopy ? true : nil,
                                   fitCoupon: fitCoupon ? true : nil)
            localModels.insert(model, at: neighbour.flatMap { id in localModels.firstIndex { $0.id == id } } ?? 0)
            if selectsAndShows { select(model) }
            saveModels()
            if selectsAndShows { self.destination = .models }
            considerPrintPreparation(for: model, origin: origin)
            return model.id
        } catch { showError(error.localizedDescription); return nil }
    }
    func select(_ model: LocalModel) { selectedLocalID = model.id; fileID = model.remoteID ?? ""; estimate = nil }
    /// Removes the model from the library and moves the app's private copy to the Trash, registering Edit › Undo
    /// when an undo manager is given. The file the user imported from, and any uploaded Slant file, are never touched.
    func removeLocalModel(id: UUID, undoManager: UndoManager? = nil) {
        guard let index = localModels.firstIndex(where: { $0.id == id }) else { return }
        let model = localModels[index]
        var trashed: TrashedLibraryFile?
        if isManagedModelCopy(model.url, supportDirectory: Self.supportDirectory), FileManager.default.fileExists(atPath: model.url.path) {
            do {
                trashed = try moveLibraryFileToTrash(model.url, displayName: model.name,
                                                     stagingRoot: Self.supportDirectory.appendingPathComponent("Removed", isDirectory: true))
            } catch {
                showError("“\(model.name)” couldn’t be moved to the Trash, so it stays in your library. \(error.localizedDescription)")
                return
            }
        }
        let wasSelected = selectedLocalID == id
        localModels.remove(at: index)
        try? FileManager.default.removeItem(at: ModelThumbnails.url(for: id))
        ThumbnailMemoryCache.shared.remove(id)
        if wasSelected {
            selectedLocalID = nil
            fileID = ""
            estimate = nil
        }
        saveModels()
        activities.insert(Activity(title: "Remove from library", detail: model.name, success: true), at: 0)
        let removed = RemovedLibraryModel(model: model, index: index, wasSelected: wasSelected, file: trashed)
        registerRestoreUndo(removed, undoManager: undoManager)
    }
    /// Edit › Undo is a menu command, so like the others it does nothing while a sheet, alert or panel is up.
    /// A blocked undo is put back on the undo stack once the current undo finishes, so it isn't lost.
    private func registerRestoreUndo(_ removed: RemovedLibraryModel, undoManager: UndoManager?) {
        undoManager?.registerUndo(withTarget: self) { [weak undoManager] store in
            MainActor.assumeIsolated {
                guard !store.menuCommandsBlockedByModalUI else {
                    NSSound.beep()
                    DispatchQueue.main.async { store.registerRestoreUndo(removed, undoManager: undoManager) }
                    return
                }
                store.restoreRemovedModel(removed, undoManager: undoManager)
            }
        }
        undoManager?.setActionName("Remove from Library")
    }
    /// Undo for `removeLocalModel`: moves the file back from the Trash and reinserts the same entry.
    func restoreRemovedModel(_ removed: RemovedLibraryModel, undoManager: UndoManager? = nil) {
        guard !localModels.contains(where: { $0.id == removed.model.id }) else { return }
        if let file = removed.file {
            do { try restoreLibraryFile(file, to: removed.model.url, name: removed.model.name) }
            catch { showError(error.localizedDescription); return }
        }
        let entry = restoredLibraryEntry(removed, deletedCloudFileIDs: deletedCloudFileIDs, currentCount: localModels.count)
        localModels.insert(entry.model, at: entry.index)
        if removed.wasSelected, selectedLocalID == nil, fileID.isEmpty { select(entry.model) }
        saveModels()
        activities.insert(Activity(title: "Restore to library", detail: entry.model.name, success: true), at: 0)
        let id = entry.model.id
        undoManager?.registerUndo(withTarget: self) { [weak undoManager] store in
            MainActor.assumeIsolated {
                // Redo is a menu command too: refuse it over modal UI (the model simply stays in the library).
                guard !store.menuCommandsBlockedByModalUI else { NSSound.beep(); return }
                // An upload may be reading the file; the confirmed removal path is disabled then too.
                guard !store.busy else { store.showError("Wait for the current task to finish, then remove “\(entry.model.name)” again."); return }
                store.removeLocalModel(id: id, undoManager: undoManager)
            }
        }
        undoManager?.setActionName("Remove from Library")
    }
    func deleteCloudModel(id: String) async -> Bool {
        guard !id.isEmpty else { return false }
        var ok = false
        let name = files.first { $0.id == id }.map(cloudModelDisplayName) ?? "This model"
        let ran = await run("Delete model from Slant", handlesError: { error in
            guard case APIError.http(403, let body, _, _) = error else { return false }
            cloudDeleteRefusal = CloudDeleteRefusal(fileID: id, name: name, slantReason: shortAPIMessage(from: body))
            return true
        }) {
            _ = try await client.request("DELETE", path: "/files/\(encodedSegment(id))")
            deletedCloudFileIDs.insert(id)
            files.removeAll { $0.id == id }
            hiddenFileIDs.remove(id)
            for index in localModels.indices where localModels[index].remoteID == id {
                localModels[index].remoteID = nil
            }
            if fileID == id {
                fileID = ""
                estimate = nil
            }
            ok = true
        }
        if ok { saveModels() }
        return ran && ok
    }
    /// Hides an uploaded model from the library on this Mac only; the file stays in the Slant account.
    func hideCloudModel(id: String) {
        hiddenFileIDs.insert(id)
        if fileID == id, selectedLocalID == nil {
            fileID = ""
            estimate = nil
        }
    }
    func unhideCloudModel(id: String) {
        hiddenFileIDs.remove(id)
    }
    func showError(_ message: String) {
        error = message
        canRetry = false
        pendingRetry = nil
    }
    func dismissError() {
        error = nil
        canRetry = false
        pendingRetry = nil
    }
    func openOrderComposer(line: OrderLine? = nil) {
        openOrderComposer(prefill: line.map { OrderComposerPrefill(lines: [$0]) })
    }

    // MARK: - Order composer prefill and reorder

    /// Opens the composer with optional prefilled lines/delivery. A composer that is already open is never
    /// replaced, so a second request can't overwrite or leak into the user's in-progress draft.
    func openOrderComposer(prefill: OrderComposerPrefill?) {
        guard !showOrderComposer else { return }
        pendingOrderPrefill = prefill
        showOrderComposer = true
    }
    func duplicateOrderBlockedReason(orderID: String) -> String? {
        orderDuplicateBlockedReason(
            draftBlockedReason: orderDraftBlockedReason, composerOpen: showOrderComposer,
            outcomeUnknown: isOutcomeUnknown(orderID: orderID), busy: busy
        )
    }
    /// Reads the order fresh (a GET only) and opens the composer prefilled for review. Nothing is created or charged
    /// here: the user still creates the draft, which Slant prices anew, and places it through the charge review.
    func duplicateOrderAsDraft(orderID: String) async {
        if let reason = duplicateOrderBlockedReason(orderID: orderID) { showError(reason); return }
        var prefill: OrderComposerPrefill?
        _ = await run("Load order to duplicate") {
            let response = try await client.request("GET", path: "/orders/\(encodedSegment(orderID))")
            noteRateLimit(from: response)
            let order = mergeOrderDraftEnvelope(responseObject(response))
            SlantAPIWatch.shared.noteOrder(order)
            guard !Record(values: order).id.isEmpty else { throw StudioError("Slant didn’t return that order. Reload Orders and try again.") }
            prefill = orderComposerPrefill(reordering: Record(values: order))
        }
        guard let prefill else { return }
        // State may have changed while loading (e.g. another composer opened or an outcome became unknown).
        if let reason = duplicateOrderBlockedReason(orderID: orderID) { showError(reason); return }
        openOrderComposer(prefill: prefill)
    }
    func refreshCurrent() async {
        if destination == .catalog || destination.isCatalogKind {
            let kind = destination == .catalog ? catalogKind : destination
            switch kind {
            case .components, .stationery:
                await loadCatalog(kind)
            default:
                await refresh()
            }
            return
        }
        await refresh()
    }
    func retryLast() async {
        guard let action = pendingRetry else { return }
        switch action {
        case .connect(let key): await connect(key: key)
        case .refresh: await refresh()
        case .loadMoreFiles: await loadMoreFiles()
        case .searchOrders(let text): await searchOrders(text)
        case .loadMoreOrders: await loadMoreOrders()
        case .loadCatalog(let kind): await loadCatalog(kind)
        case .quote: await quote()
        case .loadUsage: await loadUsage()
        case .loadHealth: await loadHealth()
        case .loadDeadWebhooks(let id): _ = await loadDeadWebhooks(platformID: id)
        case .applyOrderFilter: await applyOrderFilter(orderFilter)
        case .loadPlatform(let id): _ = await loadPlatform(id: id)
        case .loadComponentCategories: await loadComponentCategories()
        }
    }
    /// When `retryable: true`, pass a `RetryAction` from the safe set only (GETs / estimate / usage / health).
    @discardableResult
    /// `handlesError` lets a caller present its own UI for specific failures; returning true skips the generic alert.
    func run(
        _ title: String,
        retryable: Bool = false,
        retry: RetryAction? = nil,
        handlesError: (Error) -> Bool = { _ in false },
        operation: () async throws -> Void
    ) async -> Bool {
        guard !busy else { return false }
        busy = true; progress = title
        dismissError()
        defer { busy = false; progress = "" }
        do {
            try await operation()
            activities.insert(Activity(title: title, detail: "Completed", success: true), at: 0)
            canRetry = false
            pendingRetry = nil
        } catch is ConnectSuperseded {
            canRetry = false
            pendingRetry = nil
        } catch {
            if !handlesError(error) { self.error = friendlyAPIMessage(error) }
            activities.insert(Activity(title: title, detail: activityDetail(for: error), success: false), at: 0)
            if retryable, let retry {
                pendingRetry = retry
                canRetry = true
            } else {
                pendingRetry = nil
                canRetry = false
            }
        }
        activities = Array(activities.prefix(100))
        return true
    }
    /// Failed key-change attempt: drop loaded data and mark disconnected, but keep saved apiKey/platformID.
    private func clearLoadedAccountDataKeepingCredentials() {
        connected = false
        files = []; platforms = []; orders = []; filaments = []; filamentsLoadedAt = nil; components = []; stationery = []
        draft = nil; estimate = nil; activities = []; usage = nil; healthStatus = nil; rateLimit = nil
        fileID = ""; filamentID = ""
        accountLoaded = false; filesLoaded = false; ordersLoaded = false; loadedCatalogs = []
        orderSearchActive = false; fileSearchActive = false
        filePage = 0; orderPage = 0; filesHasMore = false; ordersHasMore = false
        ordersChangedWhileLoading = false; ordersFirstPageCount = nil
        lastDelivery = nil; pendingOrderPrefill = nil; orderFilter = OrderFilter()
        disabledPlatformsThisSession = []; deadWebhooks = [:]; componentCategories = []
        importedSaleAmounts = [:]
    }
    // The pay/cancel lock, the unconfirmed draft-create notice and the import ledger are deliberately NOT cleared
    // by a key change or Disconnect: Studio can't tell whether a new key belongs to the same Slant account, and a
    // write that may have reached that account must keep its safeguard for the rest of the session. Keeping them
    // after a real account switch costs at most an extra confirmation; lock entries are keyed by order ID and
    // never match another account's orders.
    private func resetAccountDataPreservingKey() {
        clearLoadedAccountDataKeepingCredentials()
        platformID = ""
        cachedClient?.invalidate(); cachedClient = nil; cachedClientKey = ""
    }
    /// Records an order whose pay/cancel outcome is unknown. `aliases` are other IDs of the same order (such as the
    /// `publicId` Slant returned for an ID typed in the Workbench): the lock is kept under each of them, and lifting it
    /// under any lifts it under all.
    func markOutcomeUnknown(orderID: String, action: OutcomeAction? = nil, reviewedStatus: String? = nil, aliases: [String] = []) {
        outcomeLocks.mark(orderID, action: action, reviewedStatus: reviewedStatus, aliases: aliases)
        unknownOutcomeOrderIDs = outcomeLocks.ids
    }
    func clearOutcomeUnknown(orderID: String) {
        outcomeLocks.clear(orderID)
        unknownOutcomeOrderIDs = outcomeLocks.ids
    }
    func unknownOutcomeContext(orderID: String) -> UnknownOutcomeContext? {
        outcomeLocks.contexts[orderID]
    }
    /// The lock's distinct orders: each group of aliases counts once.
    var unknownOutcomeOrderGroups: [Set<String>] { outcomeLocks.groups }
    func isOutcomeUnknown(orderID: String) -> Bool {
        unknownOutcomeOrderIDs.contains(orderID)
    }
    /// Records one Create Draft press (the composer's or the API Workbench's `POST /orders`) in the session's
    /// unconfirmed-draft guard: an unknown outcome adds the attempt, a confirmed creation removes the attempts for the
    /// same `recipient` name (never another name's, nor the dropped-off flag; two customers with the same name share
    /// one warning), and a definite refusal or a request never
    /// sent leaves it as it was. `recipient` is the name sent in the draft body, on success as on failure.
    func noteDraftCreateAttempt(_ attempt: DraftCreateAttempt, recipient: String, date: Date, marker: String?, platformID: String) {
        unconfirmedDraftCreatesOverflowed = unconfirmedDraftAttemptsOverflowed(
            previous: unconfirmedDraftCreates, overflowed: unconfirmedDraftCreatesOverflowed, attempt: attempt)
        unconfirmedDraftCreates = unconfirmedDraftAttempts(previous: unconfirmedDraftCreates, attempt: attempt,
                                                           recipient: recipient, date: date,
                                                           marker: marker, platformID: platformID)
    }
    func connect(key: String) async {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        let keyChanged = apiKey != trimmed
        if keyChanged {
            clearLoadedAccountDataKeepingCredentials()
        }
        connectGeneration += 1
        let generation = connectGeneration
        var succeeded = false
        let probe = APIClient(apiKey: trimmed)
        defer { probe.invalidate() }
        _ = await run("Connect to Slant 3D", retryable: true, retry: .connect(key)) {
            let response = try await probe.request("GET", path: "/filaments")
            guard generation == connectGeneration else { throw ConnectSuperseded() }
            noteRateLimit(from: response)
            try KeychainStore.save(trimmed)
            if keyChanged {
                platformID = ""
                fileID = ""; filamentID = ""
                cachedClient?.invalidate(); cachedClient = nil; cachedClientKey = ""
            }
            apiKey = trimmed
            setFilaments(responseRecords(response))
            connected = true
            loadedCatalogs.insert(.materials)
            applyDefaultFilamentIfNeeded()
            succeeded = true
        }
        guard generation == connectGeneration else { return }
        if shouldRefreshAfterConnect(succeeded: succeeded) { await refresh() }
    }
    func clearAccountSession() {
        connectGeneration += 1
        dismissError()
        apiKey = ""
        resetAccountDataPreservingKey()
    }
    /// Re-fetches the live filament list without blocking other work, so new materials and colours appear without a manual refresh.
    func refreshFilamentsIfStale(maxAge: TimeInterval = 60) async {
        guard hasKey, !filamentsRefreshing else { return }
        if let loadedAt = filamentsLoadedAt, Date().timeIntervalSince(loadedAt) < maxAge { return }
        filamentsRefreshing = true
        defer { filamentsRefreshing = false }
        let generation = connectGeneration
        do {
            let response = try await client.request("GET", path: "/filaments")
            guard generation == connectGeneration else { return }
            noteRateLimit(from: response)
            setFilaments(responseRecords(response))
            applyDefaultFilamentIfNeeded()
        } catch {
            activities.insert(Activity(title: "Check materials", detail: activityDetail(for: error), success: false), at: 0)
        }
    }
    private func setFilaments(_ records: [Record]) {
        filaments = records
        filamentsLoadedAt = Date()
        loadedCatalogs.insert(.materials)
    }
    func applyDefaultFilamentIfNeeded() {
        guard filamentID.isEmpty, let id = defaultFilamentID else { return }
        filamentID = id
    }
    func disconnect() {
        guard !busy else { return }
        connectGeneration += 1
        do {
            try KeychainStore.delete()
            clearAccountSession()
        } catch { showError(error.localizedDescription) }
    }
    func refresh() async {
        guard hasKey else { requestSettings(.account); return }
        _ = await run("Refresh", retryable: true, retry: .refresh) {
            let p = try await client.request("GET", path: "/platforms")
            noteRateLimit(from: p)
            platforms = responseRecords(p)
            loadedCatalogs.insert(.platforms)
            if platformID.isEmpty, let first = platforms.first { platformID = first.id }
            let f = try await client.request("GET", path: "/filaments")
            noteRateLimit(from: f)
            setFilaments(responseRecords(f))
            loadedCatalogs.insert(.materials)
            applyDefaultFilamentIfNeeded()
            var fileQuery = ["limit": String(listPageSize), "page": "1"]
            if !platformID.isEmpty { fileQuery["platformId"] = platformID }
            let filesResponse = try await client.request("GET", path: "/files", query: fileQuery)
            noteRateLimit(from: filesResponse)
            let fileRecords = responseRecords(filesResponse)
            files = fileRecords
            filePage = 1
            filesLoaded = true
            filesHasMore = listHasMorePages(pagination: responsePagination(filesResponse), recordCount: fileRecords.count, currentPage: 1, pageSize: listPageSize)
            let orderQuery = orderFilterQueryItems(orderFilter, page: 1, limit: listPageSize, platformID: platformID)
            let ordersResponse = try await client.request("GET", path: "/orders", query: orderQuery)
            noteRateLimit(from: ordersResponse)
            SlantAPIWatch.shared.noteOrderList(ordersResponse, firstPage: true)
            let orderRecords = responseRecords(ordersResponse)
            orders = orderFilterTrimmed(orderRecords, filter: orderFilter)
            orderPage = 1
            ordersLoaded = true
            noteOrderListFirstPage(ordersResponse, rawCount: orderRecords.count)
            orderSearchActive = false; fileSearchActive = false
            filesLoaded = true; ordersLoaded = true; accountLoaded = true
            loadedCatalogs.formUnion([.materials, .platforms])
            connected = true
        }
    }
    func loadMoreFiles() async {
        guard canLoadMoreListPages(searchActive: fileSearchActive), filesHasMore else { return }
        let next = nextListPage(lastLoadedPage: filePage)
        _ = await run("Load more models", retryable: true, retry: .loadMoreFiles) {
            var query = ["limit": String(listPageSize), "page": String(next)]
            if !platformID.isEmpty { query["platformId"] = platformID }
            let response = try await client.request("GET", path: "/files", query: query)
            noteRateLimit(from: response)
            let more = responseRecords(response)
            let known = Set(files.map(\.id))
            files.append(contentsOf: more.filter { !known.contains($0.id) })
            filePage = next; filesLoaded = true
            filesHasMore = listHasMorePages(pagination: responsePagination(response), recordCount: more.count, currentPage: next, pageSize: listPageSize)
        }
    }
    func searchOrders(_ text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            let cleared = clearedOrderSearchState()
            orderSearchActive = cleared.orderSearchActive
            orders = cleared.orders
            orderPage = cleared.orderPage
            ordersHasMore = false
            await refresh()
            return
        }
        _ = await run("Search orders", retryable: true, retry: .searchOrders(trimmed)) {
            let response = try await client.request("GET", path: "/orders", query: orderSearchQueryItems(trimmed, platformID: platformID))
            noteRateLimit(from: response)
            SlantAPIWatch.shared.noteOrderList(response, firstPage: false)
            orders = orderSearchMatchingRecords(responseRecords(response), typed: trimmed)
            orderSearchActive = true
            orderPage = 1
            ordersHasMore = false
            ordersChangedWhileLoading = false
            ordersFirstPageCount = nil
            ordersLoaded = true
        }
    }
    /// True only when the reload ran and succeeded (the order watch's Show acknowledges changes only then).
    @discardableResult
    func applyOrderFilter(_ filter: OrderFilter) async -> Bool {
        if let message = orderFilterValidationError(filter) {
            showError(message)
            return false
        }
        var reloaded = false
        _ = await run("Filter orders", retryable: true, retry: .applyOrderFilter) {
            orderFilter = filter
            orderSearchActive = false
            let query = orderFilterQueryItems(filter, page: 1, limit: listPageSize, platformID: platformID)
            let response = try await client.request("GET", path: "/orders", query: query)
            noteRateLimit(from: response)
            SlantAPIWatch.shared.noteOrderList(response, firstPage: true)
            let records = responseRecords(response)
            orders = orderFilterTrimmed(records, filter: filter)
            orderPage = 1
            noteOrderListFirstPage(response, rawCount: records.count)
            ordersLoaded = true
            reloaded = true
        }
        return reloaded
    }
    func loadMoreOrders() async {
        guard canLoadMoreListPages(searchActive: orderSearchActive), ordersHasMore else { return }
        let next = nextListPage(lastLoadedPage: orderPage)
        _ = await run("Load more orders", retryable: true, retry: .loadMoreOrders) {
            let query = orderFilterQueryItems(orderFilter, page: next, limit: listPageSize, platformID: platformID)
            let response = try await client.request("GET", path: "/orders", query: query)
            noteRateLimit(from: response)
            SlantAPIWatch.shared.noteOrderList(response, firstPage: false)
            let more = responseRecords(response)
            let known = Set(orders.map(\.id))
            orders.append(contentsOf: orderFilterTrimmed(more, filter: orderFilter).filter { !known.contains($0.id) })
            orderPage = next; ordersLoaded = true
            // Decided from Slant's raw page, never from the rows the date filter kept.
            let pagination = responsePagination(response)
            ordersHasMore = listHasMorePages(pagination: pagination, recordCount: more.count, currentPage: next, pageSize: listPageSize)
            if orderListChangedWhilePaging(firstCount: ordersFirstPageCount, latestCount: listPaginationTotalCount(pagination)) {
                ordersChangedWhileLoading = true
            }
        }
    }
    /// Page 1 of the order list (refresh or filter): has-more from Slant's raw page, and its total for Load More to compare.
    private func noteOrderListFirstPage(_ response: APIResponse, rawCount: Int) {
        let pagination = responsePagination(response)
        ordersHasMore = listHasMorePages(pagination: pagination, recordCount: rawCount, currentPage: 1, pageSize: listPageSize)
        ordersFirstPageCount = listPaginationTotalCount(pagination)
        ordersChangedWhileLoading = false
    }
    func loadCatalog(_ kind: Destination) async {
        _ = await run("Load \(kind.rawValue.lowercased())", retryable: true, retry: .loadCatalog(kind)) {
            let path: String
            switch kind { case .materials: path = "/filaments"; case .components: path = "/components"; case .stationery: path = "/stationery"; case .platforms: path = "/platforms"; default: return }
            let response = try await client.request("GET", path: path)
            noteRateLimit(from: response)
            let records = responseRecords(response)
            switch kind {
            case .materials:
                setFilaments(records)
                applyDefaultFilamentIfNeeded()
            case .components: components = records
            case .stationery: stationery = records
            case .platforms: platforms = records
            default: break
            }
            loadedCatalogs.insert(kind)
        }
    }
    @discardableResult
    func uploadSelected() async -> Bool {
        guard let id = selectedLocalID else { showError("Choose a local model and a platform before uploading."); return false }
        return await uploadModel(id: id)
    }
    @discardableResult
    func uploadModel(id: UUID) async -> Bool {
        guard let model = localModels.first(where: { $0.id == id }), !platformID.isEmpty else {
            showError("Choose a local model and a platform before uploading.")
            return false
        }
        let capturedID = model.id
        let capturedName = model.name
        let capturedURL = model.url
        let fileBytes = (try? capturedURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        if let problem = uploadSizeProblem(fileBytes: fileBytes) {
            showError(problem)
            return false
        }
        let stage = UploadStageBox()
        return await run("Upload \(capturedName)", handlesError: { error in
            // Worded by the step that failed; a confirm with an unknown outcome is remembered for this model.
            let failedStage = stage.value
            if uploadOutcomeUnknown(stage: failedStage, error: error) { unconfirmedUploadModelIDs.insert(capturedID) }
            self.error = uploadFailureMessage(stage: failedStage, error: error)
            return true
        }) {
            // Quit asks first until the upload has its answer (SlantStudioApp.swift).
            let write = SlantWritesInFlight.shared.begin(.upload)
            defer { SlantWritesInFlight.shared.end(write) }
            let response = try await client.upload(file: capturedURL, name: capturedName, platformId: platformID, ownerId: ownerID) { [weak self] next in
                stage.value = next
                Task { @MainActor in self?.progress = next.progressText }
            }
            noteRateLimit(from: response)
            let object = responseObject(response)
            // A real file ID only: `Record.id` would fall back to the name.
            guard let remoteID = uploadedFileID(object) else { throw UploadConfirmMissingFileID() }
            let record = Record(values: object)
            unconfirmedUploadModelIDs.remove(capturedID)
            if let index = localModels.firstIndex(where: { $0.id == capturedID }) {
                localModels[index].remoteID = remoteID
            }
            if shouldUpdateFileIDAfterUpload(uploadedModelID: capturedID, selectedLocalID: selectedLocalID) {
                fileID = remoteID
            }
            files.removeAll { $0.id == remoteID }; files.insert(record, at: 0)
            saveModels()
        }
    }
    func quote() async {
        applyDefaultFilamentIfNeeded()
        let chosenFilament = filamentID
        let chosenQuantity = quantity
        let context = "\(fileID)|\(chosenFilament)|\(chosenQuantity)"
        _ = await run("Estimate print cost", retryable: true, retry: .quote) {
            guard !fileID.isEmpty else { throw StudioError("Upload or select a cloud model first.") }
            var options: [String: Any] = ["quantity": chosenQuantity]
            if !chosenFilament.isEmpty { options["filamentId"] = chosenFilament }
            let response = try await client.request("POST", path: "/files/\(encodedSegment(fileID))/estimate", body: ["options": options])
            noteRateLimit(from: response)
            let object = responseObject(response)
            // The same check as Compare estimates: a reply without a usable total (or for another quantity) isn't an estimate.
            if case .unusable(let reason) = comparisonPrice(from: object, requestedQuantity: chosenQuantity) {
                throw StudioError("\(reason) Try again.")
            }
            estimate = object; estimateContext = context
        }
    }
    /// One read-only `GET /files/{id}` for a file still being analysed; its row in `files` is updated in place.
    func refreshFile(id: String) async {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        _ = await run("Check model analysis") {
            let response = try await client.request("GET", path: "/files/\(encodedSegment(trimmed))")
            noteRateLimit(from: response)
            let object = responseObject(response)
            guard uploadedFileID(object) == trimmed else { throw StudioError("Slant didn’t return this model. Refresh and try again.") }
            files = filesUpdating(files, with: object, id: trimmed)
        }
    }
    @discardableResult
    func createPlatform(_ draft: PlatformDraft) async -> Bool {
        var created = false
        let ran = await run("Create platform", handlesError: { error in
            // Never retried; Slant may have made the platform, so the copy says to reload before creating another.
            guard let message = platformCreateUnclearMessage(error) else { return false }
            self.error = message
            return true
        }) {
            let response = try await client.request("POST", path: "/platforms", body: try draft.payload())
            noteRateLimit(from: response)
            let object = responseObject(response)
            // A real platform ID only: `Record.id` would fall back to the name.
            guard let newID = platformRecordID(object) else {
                throw StudioError("Slant didn’t return the new platform’s ID. Reload platforms to check before creating another.")
            }
            let record = Record(values: object)
            platforms.removeAll { $0.id == newID }
            platforms.insert(record, at: 0)
            platformID = newID
            created = true
        }
        return ran && created
    }
    @discardableResult
    func updatePlatform(id: String, draft: PlatformDraft) async -> Bool {
        let body: [String: Any]
        do { body = try draft.payload() } catch { showError(error.localizedDescription); return false }
        // Nothing changed: nothing to send.
        guard !body.isEmpty else { return true }
        var updated = false
        let ran = await run("Update platform") {
            let response = try await client.request("PATCH", path: "/platforms/\(encodedSegment(id))", body: body)
            noteRateLimit(from: response)
            let object = responseObject(response)
            if let returnedID = platformRecordID(object) {
                platforms.removeAll { $0.id == returnedID }
                platforms.insert(Record(values: object), at: 0)
            }
            updated = true
        }
        if updated { await loadCatalog(.platforms) }
        return ran && updated
    }
    @discardableResult
    func setPlatformEnabled(id: String, enabled: Bool) async -> Bool {
        var ok = false
        let snapshot = platforms.first { $0.id == id }
        let ran = await run(enabled ? "Enable platform" : "Disable platform") {
            if enabled {
                _ = try await client.request("PATCH", path: "/platforms/\(encodedSegment(id))/enable")
                disabledPlatformsThisSession.removeAll { $0.id == id }
            } else {
                _ = try await client.request("DELETE", path: "/platforms/\(encodedSegment(id))")
                if let snapshot {
                    disabledPlatformsThisSession.removeAll { $0.id == snapshot.id }
                    disabledPlatformsThisSession.insert(snapshot, at: 0)
                }
                platforms.removeAll { $0.id == id }
                if platformID == id { platformID = "" }
            }
            ok = true
        }
        if ok { await loadCatalog(.platforms) }
        return ran && ok
    }
    func loadPlatform(id: String) async -> Record? {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        var record: Record?
        _ = await run("Load platform", retryable: true, retry: .loadPlatform(trimmed)) {
            let response = try await client.request("GET", path: "/platforms/\(encodedSegment(trimmed))")
            noteRateLimit(from: response)
            let object = responseObject(response)
            // A real platform ID only: `Record.id` would fall back to the name.
            guard platformRecordID(object) != nil else { throw StudioError("That platform wasn’t found.") }
            record = Record(values: object)
        }
        return record
    }
    func rotateWebhookSecret(platformID id: String) async -> String? {
        var secret: String?
        _ = await run("Rotate webhook secret") {
            let response = try await client.request("PATCH", path: "/platforms/\(encodedSegment(id))/webhook-secret")
            noteRateLimit(from: response)
            let object = responseObject(response)
            guard let extracted = extractedWebhookSecret(from: object) else {
                throw StudioError("Slant didn’t return a new webhook secret.")
            }
            secret = extracted
            var values = object
            if values["id"] == nil && values["publicId"] == nil { values["id"] = id }
            let record = Record(values: values)
            platforms.removeAll { $0.id == record.id || $0.id == id }
            platforms.insert(record, at: 0)
        }
        return secret
    }
    func sendTestWebhook(platformID id: String) async -> WebhookTestResult? {
        var result: WebhookTestResult?
        _ = await run("Send test webhook") {
            let response = try await client.request("POST", path: "/platforms/\(encodedSegment(id))/webhook/dummy")
            noteRateLimit(from: response)
            result = parseWebhookTestResult(from: responseObject(response))
        }
        return result
    }
    func loadDeadWebhooks(platformID id: String) async -> [Record]? {
        var records: [Record]?
        _ = await run("Load failed deliveries", retryable: true, retry: .loadDeadWebhooks(id)) {
            let response = try await client.request("GET", path: "/platforms/\(encodedSegment(id))/webhook")
            noteRateLimit(from: response)
            var loaded = responseRecords(response)
            if loaded.isEmpty, let rows = response.json as? [String: Any], let data = rows["data"] as? [[String: Any]] {
                loaded = data.map { Record(values: $0) }
            }
            records = loaded
            deadWebhooks[id] = loaded
        }
        return records
    }
    func resendDeadWebhooks(platformID id: String) async -> WebhookResendResult? {
        var result: WebhookResendResult?
        _ = await run("Resend failed deliveries") {
            let response = try await client.request("POST", path: "/platforms/\(encodedSegment(id))/webhook/resend")
            noteRateLimit(from: response)
            result = parseWebhookResendResult(from: responseObject(response))
        }
        return result
    }
    func resendDeadWebhook(platformID id: String, webhookID: String) async -> WebhookSingleResendResult? {
        var result: WebhookSingleResendResult?
        _ = await run("Resend failed delivery") {
            let response = try await client.request("POST", path: "/platforms/\(encodedSegment(id))/webhook/\(encodedSegment(webhookID))/resend")
            noteRateLimit(from: response)
            result = parseWebhookSingleResendResult(from: responseObject(response))
        }
        return result
    }
    @discardableResult
    func importModelFromURL(_ url: String, name: String) async -> Bool {
        let trimmedURL = url.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedURL.lowercased().hasPrefix("https://") else { showError("Use an https:// link to upload a model."); return false }
        guard !trimmedName.isEmpty else { showError("Enter a name for the uploaded model."); return false }
        guard !platformID.isEmpty else { showError("Choose a default platform in Settings › Account."); return false }
        let type = importModelType(url: trimmedURL, name: trimmedName)
        var ok = false
        let ran = await run("Upload model from URL", handlesError: { error in
            // `POST /files` has left the live OpenAPI; a 404 or 405 means Slant no longer takes links. An unclear reply
            // may still have added the file, so that copy says to refresh before uploading again.
            guard let message = uploadFromURLUnavailableMessage(error) ?? uploadFromURLUnclearMessage(error) else { return false }
            self.error = message
            return true
        }) {
            var body: [String: Any] = ["URL": trimmedURL, "name": trimmedName, "platformId": platformID, "type": type]
            if !ownerID.isEmpty { body["ownerId"] = ownerID }
            let response = try await client.request("POST", path: "/files", body: body)
            noteRateLimit(from: response)
            ok = true
        }
        if ok { await refresh() }
        return ran && ok
    }
    func loadUsage() async {
        _ = await run("Load usage", retryable: true, retry: .loadUsage) {
            let response = try await client.request("GET", path: "/usage")
            noteRateLimit(from: response)
            usage = responseObject(response)
        }
    }
    func loadHealth() async {
        _ = await run("Check service status", retryable: true, retry: .loadHealth) {
            let response = try await client.request("GET", path: "/health/status")
            noteRateLimit(from: response)
            healthStatus = responseObject(response)
        }
    }
    func loadComponentCategories() async {
        _ = await run("Load component categories", retryable: true, retry: .loadComponentCategories) {
            let response = try await client.request("GET", path: "/components/categories")
            noteRateLimit(from: response)
            componentCategories = responseRecords(response)
        }
    }
}

/// A platform's editable details as loaded, for sending only what changed.
struct PlatformDraftFields: Equatable {
    var name: String
    var url: String
    var description: String
    var webhookURL: String
}

struct PlatformDraft {
    var name = ""
    var url = ""
    var description = ""
    var webhookURL = ""
    /// Optional custom signing secret; only sent when non-empty. Never logged.
    var webhookSecret = ""
    /// When true, a blank webhookURL is sent as "" to clear the configured webhook.
    var clearsWebhookWhenBlank = false
    /// The platform's details when editing began (`init(platform:)`). With it, `payload()` sends only the fields the
    /// seller changed, so renaming a platform without a webhook never sends an empty `webhookURL`, and a shop address
    /// made elsewhere (such as an http:// one from the dashboard) is checked only when it is being changed.
    private(set) var original: PlatformDraftFields?

    init(name: String = "", url: String = "", description: String = "", webhookURL: String = "", webhookSecret: String = "", clearsWebhookWhenBlank: Bool = false) {
        self.name = name; self.url = url; self.description = description
        self.webhookURL = webhookURL; self.webhookSecret = webhookSecret
        self.clearsWebhookWhenBlank = clearsWebhookWhenBlank
    }
    init(platform: Record) {
        name = platform.string("name")
        url = platform.string("url")
        description = platform.string("description")
        webhookURL = platform.string("webhookURL", "webhookUrl")
        webhookSecret = ""
        clearsWebhookWhenBlank = true
        original = PlatformDraftFields(name: name, url: url, description: description, webhookURL: webhookURL)
    }

    func payload() throws -> [String: Any] {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let url = url.trimmingCharacters(in: .whitespacesAndNewlines)
        let description = description.trimmingCharacters(in: .whitespacesAndNewlines)
        let webhookURL = webhookURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let webhookSecret = webhookSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw StudioError("Enter a platform name.") }
        guard name.count <= 100 else { throw StudioError("Platform names can be at most 100 characters.") }
        guard description.count <= 500 else { throw StudioError("Descriptions can be at most 500 characters.") }
        if let original {
            return try editPayload(original: original, name: name, url: url, description: description,
                                   webhookURL: webhookURL, webhookSecret: webhookSecret)
        }
        guard Self.isWebURL(url, schemes: ["https"]) else { throw StudioError("Enter your shop’s https:// address, such as https://www.etsy.com/shop/YourShopName.") }
        var body: [String: Any] = ["name": name, "url": url]
        if !description.isEmpty {
            body["description"] = description
        } else if clearsWebhookWhenBlank {
            // Editing: empty description clears it on the platform.
            body["description"] = ""
        }
        if !webhookURL.isEmpty {
            guard Self.isWebURL(webhookURL, schemes: ["https"]) else { throw StudioError("The webhook URL must be a public https:// address.") }
            body["webhookURL"] = webhookURL
        } else if clearsWebhookWhenBlank {
            body["webhookURL"] = ""
        }
        // Docs: webhookSecret is only accepted on UPDATE; POST /platforms generates one.
        if clearsWebhookWhenBlank, !webhookSecret.isEmpty {
            try Self.validateWebhookSecret(webhookSecret)
            body["webhookSecret"] = webhookSecret
        }
        return body
    }

    /// An edit's PATCH body: only changed fields (a cleared description or webhook URL is sent as ""), plus a typed
    /// secret. Empty when nothing changed.
    private func editPayload(original: PlatformDraftFields, name: String, url: String, description: String,
                             webhookURL: String, webhookSecret: String) throws -> [String: Any] {
        var body: [String: Any] = [:]
        if name != original.name.trimmingCharacters(in: .whitespacesAndNewlines) { body["name"] = name }
        if url != original.url.trimmingCharacters(in: .whitespacesAndNewlines) {
            guard Self.isWebURL(url, schemes: ["https"]) else { throw StudioError("Enter your shop’s https:// address, such as https://www.etsy.com/shop/YourShopName.") }
            body["url"] = url
        }
        if description != original.description.trimmingCharacters(in: .whitespacesAndNewlines) { body["description"] = description }
        if webhookURL != original.webhookURL.trimmingCharacters(in: .whitespacesAndNewlines) {
            if !webhookURL.isEmpty {
                guard Self.isWebURL(webhookURL, schemes: ["https"]) else { throw StudioError("The webhook URL must be a public https:// address.") }
            }
            body["webhookURL"] = webhookURL
        }
        if !webhookSecret.isEmpty {
            try Self.validateWebhookSecret(webhookSecret)
            body["webhookSecret"] = webhookSecret
        }
        return body
    }

    static func validateWebhookSecret(_ secret: String) throws {
        guard (32...256).contains(secret.count) else {
            throw StudioError("Webhook secrets must be 32–256 characters.")
        }
        guard secret.unicodeScalars.allSatisfy({ (0x21...0x7E).contains($0.value) }) else {
            throw StudioError("Webhook secrets must be printable ASCII without spaces.")
        }
    }

    private static func isWebURL(_ text: String, schemes: Set<String>) -> Bool {
        guard let components = URLComponents(string: text), let scheme = components.scheme?.lowercased(),
              schemes.contains(scheme), let host = components.host, !host.isEmpty else { return false }
        return true
    }
}
/// Why New Order Draft… (and Import Orders…) can't start yet, or nil. Says where the platform is chosen.
func orderDraftBlockedReasonText(hasKey: Bool, platformID: String) -> String? {
    if !hasKey { return "Connect your account first." }
    if platformID.isEmpty { return "Choose a default platform in Settings › Account." }
    return nil
}
func friendlyAPIMessage(_ error: Error) -> String {
    if let api = error as? APIError { return api.userMessage }
    if let urlError = error as? URLError {
        switch urlError.code {
        case .notConnectedToInternet, .networkConnectionLost, .timedOut,
             .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed, .dataNotAllowed:
            return "Check your connection and try again."
        default: break
        }
    }
    let text = error.localizedDescription
    let line = text.split(separator: "\n").first.map(String.init) ?? text
    return line.count > 180 ? slantRequestFailedSeeActivityMessage : line
}
/// Activity is hidden unless developer tools are on, so the alert says how to reach it.
let slantRequestFailedSeeActivityMessage =
    "Slant couldn’t complete that request. To see the details, turn on Settings › Advanced › Show developer tools, then open Activity."
func activityDetail(for error: Error) -> String {
    if let api = error as? APIError { return api.activityDetail }
    return friendlyAPIMessage(error)
}
func canLoadMoreListPages(searchActive: Bool) -> Bool { !searchActive }
func nextListPage(lastLoadedPage: Int) -> Int { lastLoadedPage + 1 }
func clearedOrderSearchState() -> (orderSearchActive: Bool, orders: [Record], orderPage: Int) {
    (false, [], 0)
}
func shouldUpdateFileIDAfterUpload(uploadedModelID: UUID, selectedLocalID: UUID?) -> Bool {
    selectedLocalID == uploadedModelID
}
/// A file record's own ID (`publicFileServiceId`, `publicId` or `id`), never its name; nil when it has none.
func uploadedFileID(_ object: [String: Any]) -> String? {
    recordOwnID(object, keys: ["publicFileServiceId", "publicId", "id"])
}
/// A platform record's own ID (`publicId` or `id`), never its name; nil when it has none.
func platformRecordID(_ object: [String: Any]) -> String? {
    recordOwnID(object, keys: ["publicId", "id"])
}
/// The first of `keys` holding a non-empty string or number (trimmed), else nil.
func recordOwnID(_ object: [String: Any], keys: [String]) -> String? {
    for key in keys {
        let text: String
        if let string = object[key] as? String { text = string }
        else if let number = object[key] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() { text = number.stringValue }
        else { continue }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
    }
    return nil
}
/// `files` with the row for `id` replaced by `object` merged over it (fresh values win), in place; unchanged when the
/// row isn't listed.
func filesUpdating(_ files: [Record], with object: [String: Any], id: String) -> [Record] {
    files.map { row in
        guard row.id == id else { return row }
        return Record(values: row.values.merging(object) { _, fresh in fresh })
    }
}
/// Upload from URL's copy when Slant doesn't offer `POST /files` any more (404 or 405), else nil.
func uploadFromURLUnavailableMessage(_ error: Error) -> String? {
    guard case .http(let status, _, _, _)? = error as? APIError, status == 404 || status == 405 else { return nil }
    return "Slant didn’t accept an upload from a link. Download the file to this Mac, add it with Import Model…, then upload it from your library."
}
/// A create (Upload from URL's `POST /files`, Create Platform's `POST /platforms`) whose reply didn't make the outcome
/// clear: a 5xx or 408, an unreadable reply, or a connection failure after the request may have left the Mac. Copy
/// only: these requests are never retried, and the error's classification elsewhere is unchanged.
func slantCreateOutcomeUnclear(_ error: Error) -> Bool {
    switch error as? APIError {
    case .http(let status, _, _, _)?: return status >= 500 || status == 408
    case .invalidResponse?: return true
    case .invalidRequest?, .keychain?: return false
    case nil: break
    }
    if let urlError = error as? URLError { return !orderMutationURLErrorIsBeforeSending(urlError.code, method: "POST") }
    return false
}
/// Upload from URL's copy when Slant may have added the file anyway, else nil.
func uploadFromURLUnclearMessage(_ error: Error) -> String? {
    guard slantCreateOutcomeUnclear(error) else { return nil }
    return "\(slantUnclearReplyCause(error)), so the model may already be in your Slant files. Refresh and look for it there before uploading it again."
}
/// Create Platform's copy when Slant may have made the platform anyway, else nil.
func platformCreateUnclearMessage(_ error: Error) -> String? {
    guard slantCreateOutcomeUnclear(error) else { return nil }
    return "\(slantUnclearReplyCause(error)), so the platform may already exist. Use Reload Platforms in Settings › Account to check before creating it again."
}
/// The upload step currently running, set from `APIClient.upload`'s callback (any thread) and read on the main actor.
final class UploadStageBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stage: UploadStage?
    var value: UploadStage? {
        get { lock.lock(); defer { lock.unlock() }; return stage }
        set { lock.lock(); stage = newValue; lock.unlock() }
    }
}
func connectionFooterStatus(hasKey: Bool, connected: Bool, accountLoaded: Bool, busy: Bool) -> String {
    if connected { return "Connected to Slant 3D" }
    if !hasKey { return "Not connected" }
    if !accountLoaded && busy { return "Connecting…" }
    if !connected && !busy { return "Couldn’t reach Slant 3D" }
    return "Connecting…"
}
struct StudioError: LocalizedError { let message: String; init(_ message: String) { self.message = message }; var errorDescription: String? { message } }
func encodedSegment(_ string: String) -> String { string.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-_"))) ?? "" }
