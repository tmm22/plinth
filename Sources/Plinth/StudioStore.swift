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
let orderListChangedWhileLoadingNote = "Orders changed on Slant while loading. Refresh to see them all."

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
    /// The library model this copy was made from (its immediate source), set by every tool that saves a copy of a
    /// library model (LibraryLineage.swift). Nil for imports and for copies saved before it existed; older libraries
    /// load without it.
    var copiedFromID: UUID?
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
        copiedFromID = try? c.decodeIfPresent(UUID.self, forKey: .copiedFromID)
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
    // Trimmed before the emptiness check: `outcomeResolved` trims too, so a blank status must not get past here.
    let reloaded = reloadedStatus.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    guard !reloaded.isEmpty, let context else { return false }
    if context.action == .cancel, context.reviewedStatus.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return false }
    return outcomeResolved(action: context.action, reviewedStatus: context.reviewedStatus, reloadedStatus: reloaded)
}
/// The locked IDs a fresh read of one order lifts: each of the order's IDs (`orderOutcomeLockIDs`: the ID it was read
/// by, its `publicId` and `id`) that is locked and whose recorded attempt the reload shows the outcome of
/// (`unknownOutcomeResolvedByReload`, on Slant's own `status`, never the display status). Used by the review's Refresh
/// Order and the order detail's Refresh Order and selection (`liftOutcomeLocksResolvedByReload`). Pay Several Drafts
/// (`reloadUnknown`, under the ID it read) and the Workbench (over `orderOutcomeLockIDs`) don't call it: they keep
/// their own copies of the same rule (`unknownOutcomeResolvedByReload`), so a change here must be made there too.
/// Callers pass only a reply already checked to be this order (`orderBelongs`).
func orderOutcomeLockIDsResolvedByReload(requested: String, order: [String: Any],
                                         isLocked: (String) -> Bool,
                                         context: (String) -> UnknownOutcomeContext?) -> [String] {
    let reloadedStatus = (order["status"] as? String) ?? ""
    return orderOutcomeLockIDs(requested: requested, order: order).filter { id in
        isLocked(id) && unknownOutcomeResolvedByReload(context: context(id), reloadedStatus: reloadedStatus)
    }
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
    case .pay: return reloadedStatus.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() != "DRAFT"
    case .cancel:
        let reviewed = reviewedStatus.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let reloaded = reloadedStatus.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        // An order being made goes on to ship whether or not a refund was asked for, and Slant's status lags its
        // shipping record (29 Oct 2026), so production → SHIPPED says nothing about the cancel (owner decision,
        // 30 Oct 2026). The lock stays until a cancelled status, a definite refusal or another change.
        if orderAttentionProductionStatuses.contains(reviewed), orderFulfillmentShippedStatuses.contains(reloaded) { return false }
        return reloaded != reviewed
    }
}
/// Shared copy when pay/cancel was sent but the order status hasn’t been reloaded yet.
let unknownOutcomeBlockMessage = "This order’s last payment or cancel request didn’t confirm. Refresh the order; if its status hasn’t changed, check it in your Slant dashboard before trying again."
/// A cancel lock kept although the order moved on: it was sent while the order was being made and the order has
/// shipped since, which doesn't show whether the refund was made (`outcomeResolved`). Reloading can't lift it.
let unknownOutcomeShippedSinceCancelMessage = "Slant didn’t confirm your cancel and refund request, and the order has shipped since, which doesn’t show whether the refund was made. Check this order in your Slant dashboard. Until Slant shows the order cancelled or you quit and reopen Plinth, Plinth won’t send another cancel, duplicate this order or pay drafts in a batch."
/// The lock note for an order's review: the shipped-since note when the reload can no longer lift the lock, else
/// `unknownOutcomeBlockMessage`.
func unknownOutcomeLockMessage(context: UnknownOutcomeContext?, currentStatus: String?) -> String {
    guard let context, context.action == .cancel, let currentStatus else { return unknownOutcomeBlockMessage }
    let reviewed = context.reviewedStatus.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    let current = currentStatus.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    if orderAttentionProductionStatuses.contains(reviewed), orderFulfillmentShippedStatuses.contains(current) {
        return unknownOutcomeShippedSinceCancelMessage
    }
    return unknownOutcomeBlockMessage
}
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
/// Create Platform makes the new platform the default only when no default is set (owner decision, 30 Oct 2026).
func platformCreateBecomesDefault(currentDefault: String) -> Bool {
    currentDefault.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
}
/// A platform row without its cached secret (both names Slant has used), for when it may no longer be current.
func platformRecordClearingWebhookSecret(_ record: Record) -> Record {
    var values = record.values
    values.removeValue(forKey: "webhookSecret")
    values.removeValue(forKey: "secret")
    return Record(values: values)
}
/// A rotate whose 2xx reply carried no readable secret: Slant has rotated, but Studio doesn't know the new secret.
struct WebhookSecretNotReturned: LocalizedError {
    var errorDescription: String? { "Slant didn’t return a new webhook secret." }
}
/// Whether a webhook secret may have changed after a failed rotate or secret edit: anything except a definite refusal
/// (a 4xx other than 408/409) or a request never sent, and always after a 2xx without the new secret.
func webhookSecretMayHaveChanged(after error: Error) -> Bool {
    if error is WebhookSecretNotReturned { return true }
    return !orderMutationErrorProvesNoEffect(error, method: "PATCH")
}
/// The copy after a rotate (`saving: false`) or an edit that set a secret (`saving: true`) when the secret may have
/// changed, else nil. It never suggests sending again: a read shows the current secret.
func webhookSecretUnclearMessage(_ error: Error, saving: Bool) -> String? {
    guard webhookSecretMayHaveChanged(after: error) else { return nil }
    let cause = error is WebhookSecretNotReturned ? "Slant didn’t return the new secret" : slantUnclearReplyCause(error)
    let effect = saving ? "Slant may already have saved the new webhook secret" : "this platform’s webhook secret may already have changed"
    return "\(cause), so \(effect). Use Refresh Platform in the platform’s details to see the current secret before you update your receiver."
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
/// Upload from URL's `type`: the link's model extension when it has one (STL counts, so a name can't override it),
/// else the name's, else STL. A link such as `…/download.php` named "part.3mf" is a 3MF.
func importModelType(url: String, name: String) -> String {
    let urlExt = (URL(string: url)?.pathExtension ?? "").lowercased()
    let nameExt = (name as NSString).pathExtension
    let ext = ["stl", "obj", "3mf"].contains(urlExt) ? urlExt : nameExt
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
/// What Return's order-number lookup does with the rows that match: a found order replaces the list as the search
/// result; none keeps the loaded list and its typed filter, so the seller never loses matches they could already see
/// (a customer's name that matched loaded orders isn't an order number, and Slant finds nothing for it).
enum OrderSearchLookupOutcome: Equatable { case showFound, keepLoadedList }
func orderSearchLookupOutcome(matchCount: Int) -> OrderSearchLookupOutcome {
    matchCount > 0 ? .showFound : .keepLoadedList
}
/// The whole step after Return's lookup. A lookup that finds nothing while the list holds an earlier lookup's result
/// (`searchActive`) would otherwise leave that one order filtered by the new text, an empty list that says no loaded
/// order matches: so the list is restored first (the reload clearing the search does, `applyOrderFilter`), and only then
/// filtered by the typed text with the not-found line.
enum OrderSearchLookupStep: Equatable { case showFound, keepLoadedList, restoreLoadedList }
func orderSearchLookupStep(matchCount: Int, searchActive: Bool) -> OrderSearchLookupStep {
    switch orderSearchLookupOutcome(matchCount: matchCount) {
    case .showFound: return .showFound
    case .keepLoadedList: return searchActive ? .restoreLoadedList : .keepLoadedList
    }
}
/// The search state once a `.restoreLoadedList` reload has answered. It succeeded: the normal list, filtered by the typed
/// text, with the not-found line. It failed (or didn't run): the search stays as it is now (`searchActiveNow`): still
/// active, the earlier result is still listed and the not-found note says so (`orderSearchListMode`'s `.earlierResult`,
/// with Clear Search); no longer active (another reload restored the list meanwhile), the typed filter and its line.
func orderSearchStateAfterRestore(reloaded: Bool, searchActiveNow: Bool, typed: String) -> (searchActive: Bool, notFound: String) {
    (reloaded ? false : searchActiveNow, typed.trimmingCharacters(in: .whitespacesAndNewlines))
}
/// What the Orders list shows for the search state. `.foundOrder`: a lookup's result, whatever is typed.
/// `.typedFilter`: the loaded orders that match the typed text. `.earlierResult`: Slant found nothing for the typed text
/// and the list couldn't be restored, so it still shows the earlier lookup's result, unfiltered and said plainly.
enum OrderSearchListMode: Equatable { case foundOrder, typedFilter, earlierResult }
func orderSearchListMode(searchActive: Bool, notFound: String?, typed: String) -> OrderSearchListMode {
    guard searchActive else { return .typedFilter }
    let trimmed = typed.trimmingCharacters(in: .whitespacesAndNewlines)
    if let notFound, !trimmed.isEmpty, notFound == trimmed { return .earlierResult }
    return .foundOrder
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
    /// Library entries this build couldn't read, written back unchanged on every save (LibraryFile.swift).
    private(set) var libraryCarriedEntries: [Data] = []
    /// Set when the library file couldn't be read or kept at launch: saving is refused, so it is never replaced.
    private(set) var librarySaveBlocked = false
    /// Slant files whose library links were cleared this session (replaced, deleted, or stored into by another upload),
    /// unless a Models Replace File that sent nothing put them back (`restoreLinksAfterReplaceSentNothing`): a carried
    /// entry linked to one loses its link at the next save, like a listed model.
    private var libraryUnlinkedFileIDs: Set<String> = []
    /// Slant files stored into by a confirmed Models upload this session, each with the model whose upload it holds; any
    /// later change of that file (`noteLibraryFilesChanged`) removes it. With `libraryUnlinkedFileIDs`, it decides which
    /// links a model put back by Edit › Undo keeps (`restoredLibraryKeepsLink`).
    private var libraryFileUploadedBy: [String: UUID] = [:]
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
    /// Orders ticked "done in shop" in that sheet (ShopFollowUpDone.swift): order IDs only, saved in
    /// `shop-tracking-done.json` through `shopFollowUpDoneIDs`, forgotten on Disconnect or a key change.
    @Published var shopFollowUpDone = ShopFollowUpDoneRecord()
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
    /// The typed text whose Return lookup Slant answered with no such order (`orderSearchLookupOutcome`): the loaded
    /// list and its typed filter stay, and the note under the list says so. Cleared by the next search, reload or filter.
    @Published private(set) var orderSearchNotFound: String?
    @Published private(set) var fileSearchActive = false
    @Published var orderFilter = OrderFilter()
    @Published var selectedEndpointID: String?
    @Published var canRetry = false
    @Published var rateLimit: RateLimitInfo? {
        didSet { rateLimitObservedAt = rateLimit == nil ? nil : Date() }
    }
    /// When `rateLimit` was last set: a low remaining count without a reset time is trusted for a minute only.
    private(set) var rateLimitObservedAt: Date?
    /// After a 429 to the same-name check's file-list read: no upload's check reads again until then.
    private var uploadNameCheckRateLimitedUntil: Date?
    @Published var usage: [String: Any]?
    @Published var healthStatus: [String: Any]?
    @Published var lastDelivery: DeliveryDetails?
    @Published var disabledPlatformsThisSession: [Record] = []
    /// Platforms whose webhook secret may have changed without Studio seeing the new one (an unclear rotate, or an
    /// unclear edit that set a secret). Their cached secret is dropped until a read from Slant shows the current one.
    /// Memory only.
    @Published var webhookSecretUncertainPlatformIDs: Set<String> = []
    @Published var deadWebhooks: [String: [Record]] = [:]
    /// Local models whose last upload failed after `confirm-upload` was sent without a clear answer, so Slant may hold
    /// the file. Memory only; Models suggests Refresh before uploading again (`uploadUnconfirmedMessage`).
    @Published var unconfirmedUploadModelIDs: Set<UUID> = []
    /// Shown once by Models after an upload Slant stored in a file other library models were linked to
    /// (`uploadLinkMovedNotice`); their links were cleared.
    @Published var uploadLinkMovedMessage: String?
    /// The title of the alert that shows `uploadLinkMovedMessage`.
    var uploadLinkMovedTitle = uploadLinkMovedAlertTitle
    @Published var componentCategories: [Record] = []
    @Published var hiddenFileIDs = Set(UserDefaults.standard.stringArray(forKey: "hiddenFileIDs") ?? []) {
        didSet { UserDefaults.standard.set(hiddenFileIDs.sorted(), forKey: "hiddenFileIDs") }
    }
    @Published var cloudDeleteRefusal: CloudDeleteRefusal?
    /// Slant files deleted this session, so restoring a removed library entry never relinks to one.
    private(set) var deletedCloudFileIDs: Set<String> = []
    @Published private(set) var unknownOutcomeOrderIDs: Set<String> = []
    /// Drafts the seller hid from Orders on this Mac (HiddenDrafts.swift): order IDs only, oldest first, saved in
    /// `hidden-drafts.json`. Change only through `hideDraft`, `unhideDraft` and `forgetHiddenDrafts`.
    @Published var hiddenDraftIDs: [String] = []
    /// Orders › Status › Show Hidden Drafts, for this session only.
    @Published var showHiddenDrafts = false
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
    private var pendingRetry = ErrorRetrySlot()
    private struct ConnectSuperseded: Error {}
    enum RetryAction: Equatable {
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
    /// Application Support/Plinth, or Slant Studio's folder for a launch whose move from it failed. Decided once per
    /// launch (`AppSupportLocation`, LegacyMigration.swift).
    static var supportDirectory: URL { AppSupportLocation.directory }
    init() {
        // Done already by the App's init(), which must run first: the stored properties above read preferences before
        // this body runs. This call only guards a different start-up order.
        LegacyMigration.runAtLaunch()
        do { apiKey = try KeychainStore.load() } catch {
            // With no key loaded, the main window shows its Connect Slant Account prompt.
            showError("Plinth couldn’t read your saved Slant API key. Enter it again in Settings.")
        }
        // Read leniently: entries this build can't read are carried through, and a file that wasn't fully read is
        // kept beside it before any save can replace it (LibraryFile.swift).
        // On a launch working in Slant Studio's folder, its library file is never moved aside.
        let library = loadLibraryFile(at: Self.supportDirectory.appendingPathComponent(libraryFileName),
                                      mayMoveFile: !AppSupportLocation.copyFailedThisLaunch)
        localModels = library.read.models
        libraryCarriedEntries = library.read.carriedEntries
        librarySaveBlocked = library.saveBlocked
        if let detail = libraryLoadActivityDetail(library) {
            activities.insert(Activity(title: "Model library", detail: detail, success: false), at: 0)
        }
        // Never hides the key message above: both are shown.
        if let message = libraryLoadAlertMessage(library) { showError(error.map { "\($0)\n\n\(message)" } ?? message) }
        // A model still pointing into Slant Studio's Models folder uses its copy in this folder when there is one.
        if let remapped = libraryRemappingLegacyModelPaths(localModels, legacy: AppSupportLocation.otherDirectory,
                                                           current: Self.supportDirectory,
                                                           fileExists: { FileManager.default.fileExists(atPath: $0) }) {
            localModels = remapped
            saveModels()
        }
        if let detail = legacyMigrationActivityDetail(LegacyMigrationLaunch.outcome) {
            activities.insert(Activity(title: legacyMigrationActivityTitle, detail: detail, success: true), at: 0)
        }
        if let kept = legacyMigrationKeptSeparateActivity(LegacyMigrationLaunch.outcome) {
            activities.insert(Activity(title: kept.title, detail: kept.detail, success: true), at: 0)
        }
        savedProducts = loadSavedProducts(from: Self.supportDirectory.appendingPathComponent(savedProductsFileName))
        sellerAddress = loadSellerAddress(from: Self.sellerAddressURL)
        loadShopFollowUpDoneAtLaunch()
        hiddenDraftIDs = loadHiddenDrafts()
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
    /// Background order checks and the Workbench report the allowance they used, so the next check and Settings see it.
    func noteBackgroundRateLimit(from response: APIResponse) { noteRateLimit(from: response) }
    // MARK: -
    /// Writes the library file. False when saving is refused this session or the write failed (the reason is in
    /// `error`); a Replace File checks it before sending anything (`clearLinksBeforeReplacing`).
    @discardableResult
    func saveModels() -> Bool {
        // A library file that couldn't be read or kept is never replaced (LibraryFile.swift).
        guard !librarySaveBlocked else { showError(librarySaveBlockedMessage); return false }
        do {
            try FileManager.default.createDirectory(at: Self.supportDirectory, withIntermediateDirectories: true)
            // A carried entry never keeps a link to a file whose links were cleared, or that a listed model links.
            libraryCarriedEntries = libraryCarriedEntriesDroppingLinks(
                libraryCarriedEntries, toFileIDs: libraryUnlinkedFileIDs.union(localModels.compactMap(\.remoteID)))
            try libraryFileData(localModels, carrying: libraryCarriedEntries)
                .write(to: Self.supportDirectory.appendingPathComponent(libraryFileName), options: .atomic)
            return true
        } catch {
            showError("Could not save library: \(error.localizedDescription)")
            return false
        }
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
    func importModel(_ url: URL, recipe: PreparedPrintRecipe? = nil, improvement: DesignImprovementRecord? = nil, intent: PartIntent? = nil, reinforcement: ReinforcementRecord? = nil, autoImprovement: AutoImprovementRecord? = nil, sourceDetails: ModelSourceDetails? = nil, printPreparation: PrintPreparationRecord? = nil, inheritsZUpLock: Bool = false, origin: ModelImportOrigin, keepsPlacement: Bool = false, fromPrintReadyCopy: Bool = false, copiedFrom: UUID? = nil) -> Bool {
        importModelReturningID(url, recipe: recipe, improvement: improvement, intent: intent, reinforcement: reinforcement,
                               autoImprovement: autoImprovement, sourceDetails: sourceDetails, printPreparation: printPreparation,
                               inheritsZUpLock: inheritsZUpLock,
                               origin: origin, keepsPlacement: keepsPlacement, fromPrintReadyCopy: fromPrintReadyCopy,
                               copiedFrom: copiedFrom) != nil
    }
    /// `importModel`, returning the new model's ID. `selectsAndShows: false` adds it without changing the selection
    /// or the screen, for copies saved in the background; `insertingBefore` places it next to that model (else first).
    /// `keepsPlacement` carries a replica's chosen way up to a further copy; `filledPockets` marks a Fill Hidden Pockets
    /// copy. `copiedFrom` is the library model a copy was made from (`LocalModel.copiedFromID`).
    @discardableResult
    func importModelReturningID(_ url: URL, recipe: PreparedPrintRecipe? = nil, improvement: DesignImprovementRecord? = nil, intent: PartIntent? = nil, reinforcement: ReinforcementRecord? = nil, autoImprovement: AutoImprovementRecord? = nil, sourceDetails: ModelSourceDetails? = nil, printPreparation: PrintPreparationRecord? = nil, inheritsZUpLock: Bool = false, origin: ModelImportOrigin, selectsAndShows: Bool = true, insertingBefore neighbour: UUID? = nil, keepsPlacement: Bool = false, filledPockets: Bool = false, fromPrintReadyCopy: Bool = false, fitCoupon: Bool = false, copiedFrom: UUID? = nil) -> UUID? {
        let ext = url.pathExtension.lowercased()
        guard ["stl", "obj", "3mf"].contains(ext) else {
            showError("Plinth accepts STL, OBJ, and 3MF models.")
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
                                   fitCoupon: fitCoupon ? true : nil, copiedFromID: copiedFrom)
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
        undoManager?.setActionName(libraryRemoveModelUndoName)
    }
    /// The entry Edit › Undo puts back (`restoredLibraryEntry`): no link to a file deleted since, one a listed model links
    /// now, or one whose contents changed since this session, unless it last took this model's own confirmed upload.
    func libraryRestoredEntry(_ removed: RemovedLibraryModel) -> (model: LocalModel, index: Int) {
        restoredLibraryEntry(removed, deletedCloudFileIDs: deletedCloudFileIDs, currentCount: localModels.count,
                             linkedFileIDs: Set(localModels.compactMap(\.remoteID)),
                             changedFileIDs: libraryUnlinkedFileIDs, uploadedBy: libraryFileUploadedBy)
    }
    /// Records that these Slant files' contents changed or are in doubt (replaced, deleted, stored into by another
    /// upload, or left part-way): a carried entry loses its link to them at the next save, and a model put back by
    /// Edit › Undo never keeps one (`restoredLibraryKeepsLink`).
    private func noteLibraryFilesChanged(_ fileIDs: Set<String>) {
        // Each ID as given and trimmed, so a link spelled either way matches.
        let ids = Set(fileIDs.flatMap { [$0, $0.trimmingCharacters(in: .whitespacesAndNewlines)] })
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        libraryUnlinkedFileIDs.formUnion(ids)
        for id in ids { libraryFileUploadedBy[id] = nil }
    }
    /// Undo for `removeLocalModel`: moves the file back from the Trash and reinserts the same entry.
    func restoreRemovedModel(_ removed: RemovedLibraryModel, undoManager: UndoManager? = nil) {
        guard !localModels.contains(where: { $0.id == removed.model.id }) else { return }
        if let file = removed.file {
            do { try restoreLibraryFile(file, to: removed.model.url, name: removed.model.name) }
            catch { showError(error.localizedDescription); return }
        }
        let entry = libraryRestoredEntry(removed)
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
        undoManager?.setActionName(libraryRemoveModelUndoName)
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
            noteCloudFileDeleted(id: id)
            ok = true
        }
        if ok { saveModels() }
        return ran && ok
    }
    /// The bookkeeping after Slant confirmed a file's deletion, from Models or the API Workbench: the file leaves the
    /// list, and no library model (or the selection and its estimate) keeps a link to it. The caller saves the library.
    func noteCloudFileDeleted(id: String) {
        guard !id.isEmpty else { return }
        deletedCloudFileIDs.insert(id)
        files.removeAll { $0.id == id }
        hiddenFileIDs.remove(id)
        for index in localModels.indices where localModels[index].remoteID == id {
            localModels[index].remoteID = nil
        }
        noteLibraryFilesChanged([id])
        if fileID == id {
            fileID = ""
            estimate = nil
        }
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
        pendingRetry.clear()
    }
    /// The alert's OK, and every caller that takes the error away: also forgets Try Again's action.
    func dismissError() {
        error = nil
        canRetry = false
        pendingRetry.clear()
    }
    /// The main window's error alert closing (its presentation binding). SwiftUI may report that before or after Try
    /// Again's queued `retryLast()` runs, so this keeps the action for it; OK still calls `dismissError()`. A kept
    /// action can't be reached later: Try Again shows only while `canRetry`, which only `run` sets, with a fresh action.
    func errorAlertClosed() {
        error = nil
        canRetry = false
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
    /// `currentStatus`: Slant's own status of the order as shown (the detail's copy); nil takes the loaded row's. It only
    /// picks the lock's wording (`unknownOutcomeLockMessage`): a refresh can't lift a cancel sent while the order was
    /// being made once it has shipped, so that caption doesn't tell the seller to refresh.
    func duplicateOrderBlockedReason(orderID: String, currentStatus: String? = nil) -> String? {
        let locked = isOutcomeUnknown(orderID: orderID)
        let status = locked ? (currentStatus ?? orders.first { $0.id == orderID }.flatMap { orderObject($0.values)["status"] as? String }) : nil
        return orderDuplicateBlockedReason(
            draftBlockedReason: orderDraftBlockedReason, composerOpen: showOrderComposer,
            outcomeUnknown: locked, busy: busy,
            lockContext: locked ? unknownOutcomeContext(orderID: orderID) : nil, currentStatus: status
        )
    }
    /// Reads the order fresh (a GET only) and opens the composer prefilled for review. Nothing is created or charged
    /// here: the user still creates the draft, which Slant prices anew, and places it through the charge review.
    /// `asReprint` (Report a Problem's Reprint as New Draft…) only adds the original's number for `metadata.reprintOf`.
    func duplicateOrderAsDraft(orderID: String, asReprint: Bool = false) async {
        if let reason = duplicateOrderBlockedReason(orderID: orderID) { showError(reason); return }
        var prefill: OrderComposerPrefill?
        _ = await run("Load order to duplicate") {
            let response = try await client.request("GET", path: "/orders/\(encodedSegment(orderID))")
            noteRateLimit(from: response)
            let order = mergeOrderDraftEnvelope(responseObject(response))
            SlantAPIWatch.shared.noteOrder(order)
            guard !Record(values: order).id.isEmpty else { throw StudioError("Slant didn’t return that order. Refresh the list and try again.") }
            prefill = orderComposerPrefill(reordering: Record(values: order), asReprint: asReprint)
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
    /// Try Again: takes the failed run's action (so it runs at most once) and runs it. Only `RetryAction`'s reads, the
    /// estimate and connect are ever retried.
    func retryLast() async {
        guard let action = pendingRetry.take() else { return }
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
            pendingRetry.clear()
        } catch is ConnectSuperseded {
            canRetry = false
            pendingRetry.clear()
        } catch where runFailureIsQuietCancellation(error, taskCancelled: Task.isCancelled, retryable: retryable) {
            // A read whose view cancelled it (a `.task` restarted, or its sheet or window closed): nothing failed, so
            // no alert, no failed Activity line and no Try Again. Writes (`retryable: false`) never come here, so a
            // cancelled write keeps its own outcome handling. (No retryable run passes `handlesError`.)
            canRetry = false
            pendingRetry.clear()
        } catch {
            if !handlesError(error) { self.error = friendlyAPIMessage(error) }
            activities.insert(Activity(title: title, detail: activityDetail(for: error), success: false), at: 0)
            if runFailureOffersRetry(error, retryable: retryable), let retry {
                pendingRetry.set(retry)
                canRetry = true
            } else {
                pendingRetry.clear()
                canRetry = false
            }
        }
        activities = Array(activities.prefix(100))
        return true
    }
    /// Forgets the loaded account data and marks disconnected, keeping the saved apiKey and platformID (through
    /// `resetAccountDataPreservingKey`: a key change that passed its test, and Disconnect).
    private func clearLoadedAccountDataKeepingCredentials() {
        connected = false
        files = []; platforms = []; orders = []; filaments = []; filamentsLoadedAt = nil; components = []; stationery = []
        draft = nil; estimate = nil; activities = []; usage = nil; healthStatus = nil; rateLimit = nil
        uploadNameCheckRateLimitedUntil = nil
        fileID = ""; filamentID = ""
        accountLoaded = false; filesLoaded = false; ordersLoaded = false; loadedCatalogs = []
        orderSearchActive = false; fileSearchActive = false; orderSearchNotFound = nil
        filePage = 0; orderPage = 0; filesHasMore = false; ordersHasMore = false
        ordersChangedWhileLoading = false; ordersFirstPageCount = nil
        lastDelivery = nil; pendingOrderPrefill = nil; orderFilter = OrderFilter()
        disabledPlatformsThisSession = []; webhookSecretUncertainPlatformIDs = []; deadWebhooks = [:]; componentCategories = []
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
    /// After a by-ID read of one order (a reply already checked with `orderBelongs`): lifts its pay/cancel lock when the
    /// reload shows the recorded attempt's outcome (`orderOutcomeLockIDsResolvedByReload`), under every ID it is kept
    /// under. True when a lock was lifted.
    @discardableResult
    func liftOutcomeLocksResolvedByReload(requested: String, order: [String: Any]) -> Bool {
        let ids = orderOutcomeLockIDsResolvedByReload(
            requested: requested, order: order,
            isLocked: { isOutcomeUnknown(orderID: $0) }, context: { unknownOutcomeContext(orderID: $0) })
        for id in ids { clearOutcomeUnknown(orderID: id) }
        return !ids.isEmpty
    }
    /// The lock's distinct orders: each group of aliases counts once.
    var unknownOutcomeOrderGroups: [Set<String>] { outcomeLocks.groups }
    func isOutcomeUnknown(orderID: String) -> Bool {
        unknownOutcomeOrderIDs.contains(orderID)
    }
    /// Display only: the loaded orders the Orders list shows for the default platform (`ordersShownOnPlatform`;
    /// Slant's `GET /orders` may list other platforms' orders), keeping any order under the pay/cancel lock so its
    /// Refresh Order stays reachable. Duplicate, draft-marker, lock and charge checks read the raw `orders`, never this.
    var ordersOnDefaultPlatform: [Record] {
        ordersShownOnPlatform(orders, platformID: platformID, keeping: unknownOutcomeOrderIDs)
    }
    /// Display only: `ordersOnDefaultPlatform` less the drafts hidden on this Mac unless Show Hidden Drafts is on
    /// (HiddenDrafts.swift). Duplicate, draft-marker, lock and charge checks read the raw `orders`, never this.
    var ordersShownInList: [Record] {
        ordersShownWithoutHiddenDrafts(ordersOnDefaultPlatform, hidden: hiddenDraftIDSet, keeping: unknownOutcomeOrderIDs,
                                       showHidden: showHiddenDrafts)
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
    /// Tests `key` with a read-only `GET /filaments` and, only once Slant accepts it and the Keychain holds it, makes it
    /// the key in use. A new key is refused after its test, before the save, while a sheet or other modal UI is shown
    /// (`accountKeyChangeBlockedReason`, as Settings checks at the press), so nothing changes under it. True when the
    /// key passed (and wasn't superseded or refused); the refresh that follows doesn't change that.
    @discardableResult
    func connect(key: String) async -> Bool {
        // `run` refuses while busy (Try Again can reach this while another task holds `busy`; Settings' Save & Test is
        // disabled then).
        guard !busy else { return false }
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        let keyChanged = apiKey != trimmed
        connectGeneration += 1
        let generation = connectGeneration
        var succeeded = false
        let probe = APIClient(apiKey: trimmed)
        defer { probe.invalidate() }
        _ = await run("Connect to Slant 3D", retryable: true, retry: .connect(key)) {
            let response = try await probe.request("GET", path: "/filaments")
            guard generation == connectGeneration else { throw ConnectSuperseded() }
            // Settings checked this when Save & Test was pressed, but a sheet or dialog may have opened during the
            // test: a new key never resets the account under it. Refused before the Keychain save, so nothing changes.
            if keyChanged, let reason = accountKeyChangeBlockedReason(busy: false, modalUIShown: isPresentingSheet || appIsPresentingModalUI()) {
                throw StudioError(reason)
            }
            do { try KeychainStore.save(trimmed) } catch { throw StudioError(slantKeySaveFailedMessage) }
            if keyChanged {
                // Only now that Slant accepted the new key and the Keychain holds it: a test that fails or is
                // superseded is no key change, so the loaded data (imported sale amounts included), the connection,
                // Activity, hidden drafts and done ticks stay as they were under the key still in use. The lock,
                // unconfirmed drafts and the import ledger are never cleared here (`resetAccountDataPreservingKey`).
                resetAccountDataPreservingKey()
                forgetHiddenDrafts()
                forgetShopFollowUpDone()
            }
            // After the reset, which forgets the earlier key's allowance.
            noteRateLimit(from: response)
            apiKey = trimmed
            setFilaments(responseRecords(response))
            connected = true
            loadedCatalogs.insert(.materials)
            applyDefaultFilamentIfNeeded()
            succeeded = true
        }
        guard generation == connectGeneration else { return false }
        if shouldRefreshAfterConnect(succeeded: succeeded) { await refresh() }
        return succeeded
    }
    func clearAccountSession() {
        connectGeneration += 1
        dismissError()
        apiKey = ""
        resetAccountDataPreservingKey()
        forgetHiddenDrafts()
        forgetShopFollowUpDone()
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
            setPlatformsFromSlant(responseRecords(p))
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
            orderSearchNotFound = nil
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
    /// The seller changed the typed search: a "no order with that number" note about other text goes.
    func noteOrderSearchEdited(_ text: String) {
        guard let notFound = orderSearchNotFound,
              notFound != text.trimmingCharacters(in: .whitespacesAndNewlines) else { return }
        orderSearchNotFound = nil
    }
    func searchOrders(_ text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            // The lookup's result stays listed (and the search active) until the list is read again: a reload that
            // can't run now (another request) or fails never leaves an empty list that looks complete, here or to
            // Import Orders' duplicate check. Both reloads end the search once their read succeeds.
            guard !busy else { return }
            orderSearchNotFound = nil
            // Only the orders, with the current filter: a full refresh would also re-read platforms, materials and
            // files, dropping extra Models pages and an active Models file search. Before the account has loaded,
            // the full refresh still runs (it loads what the orders depend on).
            if orderSearchClearReloadsOnlyOrders(connected: connected, hasKey: hasKey) {
                await applyOrderFilter(orderFilter)
            } else {
                await refresh()
            }
            return
        }
        var restoreList = false
        _ = await run("Search orders", retryable: true, retry: .searchOrders(trimmed)) {
            let response = try await client.request("GET", path: "/orders", query: orderSearchQueryItems(trimmed, platformID: platformID))
            noteRateLimit(from: response)
            SlantAPIWatch.shared.noteOrderList(response, firstPage: false)
            let matches = orderSearchMatchingRecords(responseRecords(response), typed: trimmed)
            // No order with that number: keep the loaded list (and the typed filter over it), so a name that matched
            // loaded orders never empties the list. Only a found order replaces it. When the list holds an earlier
            // lookup's result, it is restored first (below), outside this request.
            switch orderSearchLookupStep(matchCount: matches.count, searchActive: orderSearchActive) {
            case .showFound: break
            case .keepLoadedList:
                orderSearchNotFound = trimmed
                return
            case .restoreLoadedList:
                restoreList = true
                return
            }
            orderSearchNotFound = nil
            orders = matches
            orderSearchActive = true
            orderPage = 1
            ordersHasMore = false
            ordersChangedWhileLoading = false
            ordersFirstPageCount = nil
            ordersLoaded = true
        }
        guard restoreList else { return }
        let reloaded = await applyOrderFilter(orderFilter)
        let after = orderSearchStateAfterRestore(reloaded: reloaded, searchActiveNow: orderSearchActive, typed: trimmed)
        orderSearchActive = after.searchActive
        orderSearchNotFound = after.notFound
    }
    /// True only when the reload ran and succeeded (the order watch's Show acknowledges changes only then).
    @discardableResult
    func applyOrderFilter(_ filter: OrderFilter) async -> Bool {
        if let message = orderFilterValidationError(filter) {
            showError(message)
            return false
        }
        var reloaded = false
        // Try Again repeats `orderFilter`, which changes only once a read succeeds: it is offered for a reload of the
        // filter shown, never for a change that failed (that would read the old filter again).
        _ = await run("Filter orders", retryable: filter == orderFilter, retry: .applyOrderFilter) {
            let query = orderFilterQueryItems(filter, page: 1, limit: listPageSize, platformID: platformID)
            let response = try await client.request("GET", path: "/orders", query: query)
            noteRateLimit(from: response)
            SlantAPIWatch.shared.noteOrderList(response, firstPage: true)
            // Only once the list is read again, with its rows: a failed or skipped reload leaves the filter, the rows
            // and any search result as they were, so the Status shown, Load More and Import Orders' duplicate check
            // never take another filter's rows for this one's.
            orderFilter = filter
            orderSearchActive = false
            orderSearchNotFound = nil
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
            case .platforms: setPlatformsFromSlant(records)
            default: break
            }
            loadedCatalogs.insert(kind)
        }
    }
    /// Reads every page of the seller's Slant files (read-only `GET /files`, all platforms, ≤ 50 pages of 100, 0.6 s
    /// apart) and checks `name` against them and the loaded list, before an upload. Slant keeps one file per owner and
    /// name, so an upload under a listed name replaces that file for every draft that uses it (30 Oct 2026). For a
    /// model linked to a cloud file (`linkedFileID`), the check uses that file's name, so Upload Again… is offered its
    /// own file (`slantUploadNameCheckResult`). Nil when the check didn't run (busy), couldn't read the whole list or
    /// stopped for the rate limit (at or below `orderWatchRateLimitReserve` left, or after a 429); the reason is then in
    /// `error` and nothing may be uploaded. `retryHint` names how to try again where the check was started. The list
    /// read here feeds the check and the pre-PUT guard only and never replaces `files`. Never retried.
    func checkUploadName(_ name: String, linkedFileID: String? = nil,
                         retryHint: String = slantUploadNameCheckRetryInModels) async -> SlantUploadNameCheckResult? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        var result: SlantUploadNameCheckResult?
        let generation = connectGeneration
        _ = await run("Check Slant file names", handlesError: { error in
            if error is SlantUploadNameCheckRateLimited {
                self.error = slantUploadNameCheckRateLimitedMessage
            } else if error is SlantUploadNameCheckTooManyFiles {
                self.error = slantUploadNameCheckTooManyFilesMessage
            } else {
                self.error = slantUploadNameCheckFailedMessage(name: trimmed, reason: friendlyAPIMessage(error), retryHint: retryHint)
            }
            return true
        }) {
            progress = "Checking your Slant files…"
            var listed: [Record] = []
            var page = 1
            var lastRequest: Date?
            while true {
                // Leave the allowance to the seller's orders and the order watch: stop, never wait and read on.
                if slantUploadNameCheckRateLimitStop(rateLimit: rateLimit, observedAt: rateLimitObservedAt,
                                                     rateLimitedUntil: uploadNameCheckRateLimitedUntil, now: Date()) {
                    throw SlantUploadNameCheckRateLimited()
                }
                if let lastRequest {
                    let wait = comparisonMinimumSpacing - Date().timeIntervalSince(lastRequest)
                    if wait > 0 { try await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }
                }
                lastRequest = Date()
                let response: APIResponse
                do {
                    response = try await client.request("GET", path: "/files", query: ["limit": String(listPageSize), "page": String(page)])
                } catch APIError.http(429, _, let retryAfter, let reset) {
                    uploadNameCheckRateLimitedUntil = comparisonRateLimitedUntil(retryAfter: retryAfter, rateLimitReset: reset, now: Date())
                    throw SlantUploadNameCheckRateLimited()
                }
                guard generation == connectGeneration else { throw StudioError("The Slant account changed while checking.") }
                noteRateLimit(from: response)
                guard slantFileNamePageIsReadable(response.json) else {
                    throw APIError.invalidResponse("Slant’s reply didn’t list your files’ names.")
                }
                let rows = responseRecords(response)
                listed.append(contentsOf: rows)
                guard listHasMorePages(pagination: responsePagination(response), recordCount: rows.count,
                                       currentPage: page, pageSize: listPageSize) else { break }
                guard page < slantUploadNameCheckMaxPages else { throw SlantUploadNameCheckTooManyFiles() }
                page += 1
            }
            result = slantUploadNameCheckResult(name: trimmed, linkedFileID: linkedFileID, files: listed + files)
        }
        return result
    }
    /// Uploads a library model under `uploadName`, which the caller has checked with `checkUploadName` (and, for a
    /// listed name, the seller chose to replace the file in `replacing`). Never retried. The
    /// pre-PUT guard (`APIClient.upload`) stops before any bytes are sent when Slant offers to store the upload in one of
    /// `protectedFiles` (every file the check read, less the one being replaced; no default, so every caller passes them)
    /// or every library model's link. If Slant returns a file another library model is
    /// linked to, that file now holds this model: only this model keeps the link, and `uploadLinkMovedMessage` says so.
    /// After a Replace File that failed once the PUT may have started, every model linked to the replaced file (this
    /// one included) loses its link (`uploadReplacementMayBePartial`); one that stopped before any bytes could be sent
    /// puts back the links it cleared before sending, where that is still safe (`restoreLinksAfterReplaceSentNothing`).
    /// True only when the upload was confirmed and this model is linked to the file Slant returned.
    @discardableResult
    func uploadModel(id: UUID, as uploadName: String, replacing: UploadReplacement?,
                     protectedFiles: [String: String]) async -> Bool {
        guard let model = localModels.first(where: { $0.id == id }), !platformID.isEmpty else {
            showError("Choose a local model and a platform before uploading.")
            return false
        }
        // An upload saves which model is linked to which Slant file (and, for a Replace File, saves the unlinking
        // before anything is sent). While library saves are refused that can't be recorded, so nothing is uploaded.
        guard !librarySaveBlocked else { showError(libraryUploadBlockedMessage); return false }
        let capturedID = model.id
        let capturedName = uploadName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? model.name : uploadName
        let capturedURL = model.url
        let fileBytes = (try? capturedURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        if let problem = uploadSizeProblem(fileBytes: fileBytes) {
            showError(problem)
            return false
        }
        let stage = UploadStageBox()
        let target = UploadTargetBox()
        var succeeded = false
        // Library links are protected too (a linked file may be missing from the list just read); only the file the
        // seller chose to replace may be written over.
        let guarded = uploadProtectedFilesAddingLibraryLinks(protectedFiles, models: localModels, replacing: replacing?.fileID)
        let replacedFileID = replacing?.fileID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        // What a Replace File's unlinking before sending changed (this model's own link included); nil when nothing
        // was cleared.
        var clearedBeforeSending: ReplaceFileClearedLinks?
        var unlinkedBeforeSending: [String] = []
        let ran = await run("Upload \(capturedName)", handlesError: { error in
            // Worded by the step that failed; a confirm with an unknown outcome is remembered for this model.
            let failedStage = stage.value
            let replacedID = replacing.map { $0.fileID ?? target.value ?? "" }
            if uploadReplacementMayBePartial(stage: failedStage, replacingFileID: replacedID) {
                // The replaced file (or the one Slant chose) may now hold part of this model: no model keeps a link to it.
                let changed = Set([replacing?.fileID, target.value].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty })
                let others = unlinkedBeforeSending + self.clearLinks(toFileIDs: changed, alsoUnlinking: capturedID)
                // The bar shows the failed state (Upload Again), never "select it to estimate and order".
                unconfirmedUploadModelIDs.remove(capturedID)
                saveModels()
                self.error = uploadReplacementPartialMessage(fileName: replacing?.fileName ?? "", modelName: model.name, otherModelNames: others)
                return true
            }
            if uploadOutcomeUnknown(stage: failedStage, error: error) {
                unconfirmedUploadModelIDs.insert(capturedID)
            }
            // Once the PUT may have started, the file Slant offered may hold some of this model: a model put back by
            // Undo (or a carried entry) never keeps a link to it. The pre-PUT guard kept every listed model's file safe.
            if failedStage == .uploading || failedStage == .confirming, let offered = target.value {
                noteLibraryFilesChanged([offered])
            }
            var message = uploadFailureMessage(stage: failedStage, error: error)
            // A Replace File that stopped before any bytes could be sent: the replaced file still holds what it held, so
            // the links cleared before asking Slant come back where that is still safe. Only the models left unlinked
            // are named; when every link came back, the message needs nothing more.
            if let cleared = clearedBeforeSending, !uploadReplacementMayBePartial(stage: failedStage, replacingFileID: replacedID) {
                let restored = self.restoreLinksAfterReplaceSentNothing(cleared)
                if let note = uploadReplacementRestoreNote(fileName: replacing?.fileName ?? "", leftUnlinked: restored.leftUnlinked,
                                                           restoreNotSaved: restored.notSaved) {
                    message += " \(note)"
                }
            }
            self.error = message
            return true
        }) {
            // Quit asks first until the upload has its answer (PlinthApp.swift).
            let write = SlantWritesInFlight.shared.begin(.upload)
            defer { SlantWritesInFlight.shared.end(write) }
            // A Replace File unlinks every model from the replaced file before anything is sent, and saves that, so a
            // quit or crash mid-upload never leaves a model linked to a file that may hold another model's bytes. A
            // confirmed upload links this model again; a stop before any bytes could be sent puts the links back. When
            // the unlinking can't be saved, nothing is sent.
            if !replacedFileID.isEmpty {
                let cleared = try clearLinksBeforeReplacing(fileID: replacedFileID, alsoUnlinking: capturedID)
                clearedBeforeSending = cleared
                unlinkedBeforeSending = cleared.otherNames
            }
            // The pre-PUT guard runs inside `upload`, before any bytes are sent: never into `guarded`, and a Replace File
            // only into the file the seller chose. The file Slant offered is recorded first, for the failure handling.
            let response = try await client.upload(file: capturedURL, name: capturedName, platformId: platformID, ownerId: ownerID,
                                                   protectedFiles: guarded, replacing: replacing,
                                                   onPlaceholder: { placeholder in
                target.value = uploadPlaceholderFileID(placeholder)
            }) { [weak self] next in
                stage.value = next
                Task { @MainActor in self?.progress = next.progressText }
            }
            noteRateLimit(from: response)
            let object = responseObject(response)
            // A real file ID only: `Record.id` would fall back to the name.
            guard let remoteID = uploadedFileID(object) else { throw UploadConfirmMissingFileID() }
            let record = Record(values: object)
            unconfirmedUploadModelIDs.remove(capturedID)
            // Slant keeps one file per owner and name, so it may have stored this upload in a file other library models
            // are linked to: that file now holds this model, so only this model keeps the link.
            let unlinked = modelsLosingLinkAfterUpload(fileID: remoteID, uploadedModelID: capturedID, in: localModels)
            // A Replace File that Slant confirmed under another file: the chosen file wasn't replaced, and the models
            // unlinked from it before sending stay unlinked (`noteReplaceSavedElsewhere`).
            let savedElsewhere = clearedBeforeSending != nil && remoteID != replacedFileID
            let movedNames = localModels.filter { unlinked.contains($0.id) }.map(\.name)
            for index in localModels.indices where unlinked.contains(localModels[index].id) {
                localModels[index].remoteID = nil
            }
            if let index = localModels.firstIndex(where: { $0.id == capturedID }) {
                localModels[index].remoteID = remoteID
                succeeded = true
            }
            // That file now holds this model: a model put back by Undo keeps a link to it only if it is this one.
            noteLibraryFilesChanged([remoteID])
            libraryFileUploadedBy[remoteID] = capturedID
            // The same file ID may now hold different contents, so an estimate for it is no longer current.
            if fileID == remoteID { estimate = nil }
            if shouldUpdateFileIDAfterUpload(uploadedModelID: capturedID, selectedLocalID: selectedLocalID) {
                fileID = remoteID
            } else if let selected = selectedLocalID, unlinked.contains(selected) {
                fileID = ""
            }
            if savedElsewhere {
                noteReplaceSavedElsewhere(uploadedName: model.name, fileName: replacing?.fileName ?? "", unlinkedNames: unlinkedBeforeSending,
                                          moved: uploadLinkMovedNotice(uploadedName: model.name, otherNames: movedNames))
            } else {
                showUploadLinkMoved(uploadLinkMovedNotice(uploadedName: model.name, otherNames: unlinkedBeforeSending + movedNames))
            }
            files.removeAll { $0.id == remoteID }; files.insert(record, at: 0)
            saveModels()
        }
        return ran && succeeded
    }
    /// Clears the link of every library model linked to one of `fileIDs`, and of `alsoUnlinking`, after a replace whose
    /// outcome leaves those files' contents in doubt. A selected file or estimate that points at one of them is cleared
    /// too. The names of the other models that lost a link, in library order. The caller saves the library.
    private func clearLinks(toFileIDs fileIDs: Set<String>, alsoUnlinking modelID: UUID?) -> [String] {
        let affected = modelsLinked(toFileIDs: fileIDs, in: localModels)
        noteLibraryFilesChanged(fileIDs)
        let others = localModels.filter { affected.contains($0.id) && $0.id != modelID }.map(\.name)
        for index in localModels.indices where affected.contains(localModels[index].id) || localModels[index].id == modelID {
            localModels[index].remoteID = nil
        }
        let selected = fileID.trimmingCharacters(in: .whitespacesAndNewlines)
        if fileIDs.contains(selected) || selectedLocalID.map({ affected.contains($0) || $0 == modelID }) == true {
            fileID = ""
            estimate = nil
        }
        return others
    }
    /// A Replace File's unlinking before anything is sent (`clearLinks`), saved. When the save fails, everything it
    /// changed (links, the selected file and estimate, the unlinked IDs and carried entries) is put back as it was and
    /// `LibraryNotSavedBeforeUpload` is thrown, so nothing is sent. Synchronous, while `busy` is held: nothing else
    /// changes the library between the snapshot and the restore. Returns what it changed (`ReplaceFileClearedLinks`:
    /// the names of the other models unlinked, and what a Models Replace File that sent nothing puts back).
    private func clearLinksBeforeReplacing(fileID replacedID: String, alsoUnlinking modelID: UUID?) throws -> ReplaceFileClearedLinks {
        let models = localModels, selectedFile = fileID, selectedEstimate = estimate
        let unlinkedIDs = libraryUnlinkedFileIDs, uploadedBy = libraryFileUploadedBy, carried = libraryCarriedEntries
        let selectedModel = selectedLocalID
        let links = replaceFileClearedLinks(models: models, replacedFileID: replacedID, uploadedModelID: modelID)
        let others = clearLinks(toFileIDs: [replacedID], alsoUnlinking: modelID)
        guard saveModels() else {
            localModels = models
            fileID = selectedFile
            estimate = selectedEstimate
            libraryUnlinkedFileIDs = unlinkedIDs
            libraryFileUploadedBy = uploadedBy
            libraryCarriedEntries = carried
            throw LibraryNotSavedBeforeUpload()
        }
        return ReplaceFileClearedLinks(replacedFileID: replacedID, links: links, otherNames: others,
                                       addedChangedFileIDs: libraryUnlinkedFileIDs.subtracting(unlinkedIDs),
                                       removedUploaders: uploadedBy.filter { libraryFileUploadedBy[$0.key] == nil },
                                       selectedLocalID: selectedModel, selectedFileID: selectedFile)
    }
    /// After a Models Replace File that stopped before any bytes could be sent (`uploadReplacementMayBePartial` false:
    /// at `.preparing` or earlier), the replaced file still holds what it held, so the links `clearLinksBeforeReplacing`
    /// cleared come back where that is still safe (`replaceFileLinksToRestore`), with the Undo bookkeeping that unlinking
    /// added (`addedChangedFileIDs`, `removedUploaders`) and the selected file (`replaceFileSelectedFileAfterRestore`).
    /// Targeted, never a whole snapshot from before the upload: models were imported, removed, renamed or selected
    /// meanwhile. Carried entries keep their dropped links and the estimate stays cleared (the cautious direction). The
    /// restore is saved; when that save fails, everything is put back as it was before the restore, so the library in
    /// memory matches the file (links cleared). Synchronous, from the upload's `handlesError` while `busy` is held.
    /// Returns the names of the models left unlinked and whether the restore couldn't be saved.
    private func restoreLinksAfterReplaceSentNothing(_ cleared: ReplaceFileClearedLinks) -> (leftUnlinked: [String], notSaved: Bool) {
        let restoring = replaceFileLinksToRestore(cleared.links, models: localModels)
        let models = localModels, selectedFile = fileID
        let unlinkedIDs = libraryUnlinkedFileIDs, uploadedBy = libraryFileUploadedBy, carried = libraryCarriedEntries
        for index in localModels.indices {
            if let link = restoring[localModels[index].id] { localModels[index].remoteID = link }
        }
        // Only what this unlinking added: an earlier change to the file stays on record.
        libraryUnlinkedFileIDs.subtract(cleared.addedChangedFileIDs)
        for (id, uploader) in cleared.removedUploaders where libraryFileUploadedBy[id] == nil {
            libraryFileUploadedBy[id] = uploader
        }
        if let restoredFile = replaceFileSelectedFileAfterRestore(
            selectedLocalID: selectedLocalID, fileID: fileID, restored: restoring,
            clearedSelection: (localID: cleared.selectedLocalID, fileID: cleared.selectedFileID),
            replacedFileID: cleared.replacedFileID) {
            fileID = restoredFile
        }
        // No link came back: the file on disk already says what memory says.
        guard !restoring.isEmpty else {
            return (replaceFileModelsLeftUnlinked(cleared.links, restoring: restoring, models: localModels), false)
        }
        guard saveModels() else {
            localModels = models
            fileID = selectedFile
            libraryUnlinkedFileIDs = unlinkedIDs
            libraryFileUploadedBy = uploadedBy
            libraryCarriedEntries = carried
            return (replaceFileModelsLeftUnlinked(cleared.links, restoring: [:], models: localModels), true)
        }
        return (replaceFileModelsLeftUnlinked(cleared.links, restoring: restoring, models: localModels), false)
    }
    /// Shows the notice after an upload took over a file other library models were linked to (nil: nothing to say).
    private func showUploadLinkMoved(_ notice: String?) {
        guard let notice else { return }
        uploadLinkMovedTitle = uploadLinkMovedAlertTitle
        uploadLinkMovedMessage = notice
    }
    /// The notice after a Replace File that Slant confirmed under another file than the one chosen, followed by
    /// `moved` (models linked to the file Slant used, which lost their links).
    private func noteReplaceSavedElsewhere(uploadedName: String, fileName: String, unlinkedNames: [String], moved: String?) {
        let notice = uploadReplaceSavedElsewhereNotice(uploadedName: uploadedName, fileName: fileName, unlinkedNames: unlinkedNames)
        uploadLinkMovedTitle = uploadReplaceSavedElsewhereAlertTitle
        uploadLinkMovedMessage = [notice, moved].compactMap { $0 }.joined(separator: " ")
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
                throw StudioError("Slant didn’t return the new platform’s ID. Refresh Platforms in Settings › Account to check before creating another.")
            }
            let record = Record(values: object)
            platforms.removeAll { $0.id == newID }
            platforms.insert(record, at: 0)
            // Owner decision (30 Oct 2026): a new platform becomes the default only when none is set. Changing the
            // default moves uploads and drafts, resets the order watch and stops an Import Orders batch.
            if platformCreateBecomesDefault(currentDefault: platformID) { platformID = newID }
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
        let setsSecret = body["webhookSecret"] != nil
        var updated = false
        let ran = await run("Update platform", handlesError: { error in
            // Never re-sent. A secret that may have been saved makes the cached one unreliable.
            guard setsSecret, let message = webhookSecretUnclearMessage(error, saving: true) else { return false }
            self.markWebhookSecretUncertain(platformID: id)
            self.error = message
            return true
        }) {
            let response = try await client.request("PATCH", path: "/platforms/\(encodedSegment(id))", body: body)
            noteRateLimit(from: response)
            let object = responseObject(response)
            if let returnedID = platformRecordID(object) {
                platforms.removeAll { $0.id == returnedID }
                platforms.insert(Record(values: object), at: 0)
            }
            // Slant saved a new secret, but a reply that doesn't show it can't replace the cached one: Show and Copy
            // go until the reload below (or Refresh Platform) reads it. Nothing is re-sent.
            if setsSecret, platformRecordID(object) == nil || extractedWebhookSecret(from: object) == nil {
                markWebhookSecretUncertain(platformID: id)
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
            let response: APIResponse
            if enabled {
                response = try await client.request("PATCH", path: "/platforms/\(encodedSegment(id))/enable")
            } else {
                response = try await client.request("DELETE", path: "/platforms/\(encodedSegment(id))")
            }
            noteRateLimit(from: response)
            notePlatformEnabledChange(id: id, enabled: enabled, snapshot: snapshot)
            ok = true
        }
        if ok { await loadCatalog(.platforms) }
        return ran && ok
    }
    /// The bookkeeping after Slant confirmed an enable or disable, from Settings or the API Workbench: the session's
    /// disabled list (Settings' re-enable rows) and, for a disable, the platform list and the default.
    func notePlatformEnabledChange(id: String, enabled: Bool, snapshot: Record?) {
        if enabled {
            disabledPlatformsThisSession.removeAll { $0.id == id }
        } else {
            if let snapshot {
                disabledPlatformsThisSession.removeAll { $0.id == snapshot.id }
                disabledPlatformsThisSession.insert(snapshot, at: 0)
            }
            platforms.removeAll { $0.id == id }
            if platformID == id { platformID = "" }
        }
    }
    /// Every replacement of the platform list by a read from Slant: those platforms' secrets are current again.
    private func setPlatformsFromSlant(_ records: [Record]) {
        platforms = records
        webhookSecretUncertainPlatformIDs.subtract(records.map(\.id))
    }
    /// After a secret change whose outcome is unclear: drops the cached secret (Show and Copy go with it) until a read
    /// from Slant shows the current one (`reloadPlatform`: Refresh Platform; or Refresh Platforms).
    func markWebhookSecretUncertain(platformID id: String) {
        guard !id.isEmpty else { return }
        platforms = platforms.map { $0.id == id ? platformRecordClearingWebhookSecret($0) : $0 }
        webhookSecretUncertainPlatformIDs.insert(id)
    }
    /// One read-only `GET /platforms/{id}` (never a write): replaces that platform's listed row, secret included.
    @discardableResult
    func reloadPlatform(id: String) async -> Bool {
        guard let record = await loadPlatform(id: id), record.id == id else { return false }
        if let index = platforms.firstIndex(where: { $0.id == id }) { platforms[index] = record }
        webhookSecretUncertainPlatformIDs.remove(id)
        return true
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
        _ = await run("Rotate webhook secret", handlesError: { error in
            // Never re-sent. Unless Slant definitely refused it, the old secret may already have stopped working.
            guard let message = webhookSecretUnclearMessage(error, saving: false) else { return false }
            self.markWebhookSecretUncertain(platformID: id)
            self.error = message
            return true
        }) {
            let response = try await client.request("PATCH", path: "/platforms/\(encodedSegment(id))/webhook-secret")
            noteRateLimit(from: response)
            let object = responseObject(response)
            guard let extracted = extractedWebhookSecret(from: object) else {
                throw WebhookSecretNotReturned()
            }
            secret = extracted
            var values = object
            if values["id"] == nil && values["publicId"] == nil { values["id"] = id }
            let record = Record(values: values)
            platforms.removeAll { $0.id == record.id || $0.id == id }
            platforms.insert(record, at: 0)
            webhookSecretUncertainPlatformIDs.remove(id)
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
    /// `POST /files` (one step: Slant fetches the link itself). The pre-PUT guard can't run here, because Slant
    /// returns no placeholder before it stores the file. `replacingFileID`/`replacingFileName` name the file the seller
    /// chose to replace (nil: not a Replace File; blank: its ID isn't known): when the outcome is unclear, every library
    /// model linked to it loses its link. `typeHintName` is the name the seller typed, which gives the `type` when the
    /// link has no model extension (a Replace File sends the listed file's own name, which may have none) and names the
    /// upload in the notices afterwards; nil: `name`.
    @discardableResult
    func importModelFromURL(_ url: String, name: String, typeHintName: String? = nil, replacingFileID: String? = nil,
                            replacingFileName: String = "") async -> Bool {
        let trimmedURL = url.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedURL.lowercased().hasPrefix("https://") else { showError("Use an https:// link to upload a model."); return false }
        guard !trimmedName.isEmpty else { showError("Enter a name for the uploaded model."); return false }
        guard !platformID.isEmpty else { showError("Choose a default platform in Settings › Account."); return false }
        guard !librarySaveBlocked else { showError(libraryUploadBlockedMessage); return false }
        let hint = typeHintName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        // The name the seller typed: a Replace File sends the replaced file's own name instead.
        let typedName = hint.isEmpty ? trimmedName : hint
        let type = importModelType(url: trimmedURL, name: typedName)
        // Nil: not a Replace File. Blank: a Replace File whose file ID isn't known (no link can be cleared by it).
        let replaced = replacingFileID?.trimmingCharacters(in: .whitespacesAndNewlines)
        var ok = false
        var unlinkedBeforeSending: [String] = []
        let ran = await run("Upload model from URL", handlesError: { error in
            // A Replace File that Slant definitely didn't act on: the links cleared before sending stay cleared.
            let unlinkedNote = uploadReplacementUnlinkedNote(fileName: replacingFileName, modelNames: unlinkedBeforeSending)
            // `POST /files` has left the live OpenAPI; a 404 or 405 means Slant no longer takes links. An unclear reply
            // may still have added the file, so that copy says to refresh before uploading again.
            if let message = uploadFromURLUnavailableMessage(error) {
                self.error = [message, unlinkedNote].compactMap { $0 }.joined(separator: " ")
                return true
            }
            guard uploadFromURLUnclearMessage(error) != nil else {
                guard let unlinkedNote else { return false }
                self.error = "\(friendlyAPIMessage(error)) \(unlinkedNote)"
                return true
            }
            if let replaced {
                // A Replace File with an unclear outcome: the replaced file may now hold this link's model.
                let others = unlinkedBeforeSending + self.clearLinks(toFileIDs: replaced.isEmpty ? [] : [replaced], alsoUnlinking: nil)
                saveModels()
                self.error = uploadFromURLReplaceUnclearMessage(error, fileName: replacingFileName, modelNames: others)
            } else {
                self.error = uploadFromURLUnclearMessage(error)
            }
            return true
        }) {
            var body: [String: Any] = ["URL": trimmedURL, "name": trimmedName, "platformId": platformID, "type": type]
            let owner = ownerID.trimmingCharacters(in: .whitespacesAndNewlines)
            if !owner.isEmpty { body["ownerId"] = owner }
            // Quit asks first until Slant answers, as for a Models upload (PlinthApp.swift).
            let write = SlantWritesInFlight.shared.begin(.upload)
            defer { SlantWritesInFlight.shared.end(write) }
            // A Replace File unlinks every model from the replaced file before sending (saved), so neither a quit, a
            // crash nor a reply without a file ID leaves a model linked to a file that may now hold this link's model.
            // When that can't be saved, nothing is sent.
            if let replaced, !replaced.isEmpty {
                unlinkedBeforeSending = try clearLinksBeforeReplacing(fileID: replaced, alsoUnlinking: nil).otherNames
            }
            let response = try await client.request("POST", path: "/files", body: body)
            noteRateLimit(from: response)
            ok = true
            // Slant keeps one file per owner and name: a library model linked to the file it returns no longer has its
            // own contents there, so its link is cleared (the seller chose Replace File to get here).
            if let returnedID = uploadedFileID(responseObject(response)) {
                // A Replace File that Slant confirmed under another file: the chosen file wasn't replaced, and the models
                // unlinked from it before sending stay unlinked.
                let savedElsewhere = !(replaced ?? "").isEmpty && returnedID != replaced
                let moved = noteFileContentsReplaced(fileID: returnedID, uploadedName: typedName,
                                                     alreadyUnlinked: savedElsewhere ? [] : unlinkedBeforeSending)
                if savedElsewhere {
                    noteReplaceSavedElsewhere(uploadedName: typedName, fileName: replacingFileName,
                                              unlinkedNames: unlinkedBeforeSending, moved: moved)
                }
            } else if let notice = uploadFromURLReplaceNoFileIDNotice(uploadedName: typedName, fileName: replacingFileName,
                                                                     unlinkedNames: unlinkedBeforeSending) {
                // Slant took a Replace File without naming the file it used: the models unlinked before sending stay
                // unlinked, and the seller is told which.
                uploadLinkMovedTitle = uploadFromURLNoFileIDAlertTitle
                uploadLinkMovedMessage = notice
            }
        }
        if ok { await refresh() }
        return ran && ok
    }
    /// After Slant confirmed that `fileID` now holds a model uploaded from outside the library (Upload from URL, or a
    /// Workbench `POST /files` or `confirm-upload`): Slant keeps one file per owner and name, so no library model (or
    /// carried entry) keeps a link to that file, and an estimate for it is no longer current. `alreadyUnlinked` names
    /// the models a Replace File unlinked from it before sending. Saves the library and shows the notice when anything
    /// changed, and returns that notice (nil when no model lost a link).
    @discardableResult
    func noteFileContentsReplaced(fileID returnedID: String, uploadedName: String, alreadyUnlinked: [String]) -> String? {
        // The same file ID may now hold different contents, so an estimate for it is no longer current.
        if fileID == returnedID { estimate = nil }
        let unlinked = modelsLosingLinkAfterUpload(fileID: returnedID, uploadedModelID: nil, in: localModels)
        // A carried entry linked to that file loses its link too (at this save, or the next one).
        let carriedBefore = libraryCarriedEntries
        noteLibraryFilesChanged([returnedID])
        libraryCarriedEntries = libraryCarriedEntriesDroppingLinks(libraryCarriedEntries, toFileIDs: [returnedID])
        guard !unlinked.isEmpty || !alreadyUnlinked.isEmpty || libraryCarriedEntries != carriedBefore else { return nil }
        let names = alreadyUnlinked + localModels.filter { unlinked.contains($0.id) }.map(\.name)
        for index in localModels.indices where unlinked.contains(localModels[index].id) {
            localModels[index].remoteID = nil
        }
        if let selected = selectedLocalID, unlinked.contains(selected) { fileID = "" }
        saveModels()
        let notice = uploadLinkMovedNotice(uploadedName: uploadedName, otherNames: names)
        showUploadLinkMoved(notice)
        return notice
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
/// Save & Test's Keychain save failed (locked, or access denied): `APIError.keychain`'s own copy is about reading the
/// saved key. Keep it within `friendlyAPIMessage`'s 180 characters.
let slantKeySaveFailedMessage =
    "Plinth couldn’t save the key in the Keychain. Unlock your login keychain or allow access when asked, then press Save & Test again."
/// True for a read-only run (`retryable`) that failed only because its task was cancelled (SwiftUI cancels a `.task`
/// when its ID changes or its view goes): URLSession reports that as `URLError(.cancelled)`. `invalidate()` cancels
/// requests without cancelling the task, so a key change is still reported.
func runFailureIsQuietCancellation(_ error: Error, taskCancelled: Bool, retryable: Bool) -> Bool {
    guard retryable, taskCancelled else { return false }
    return error is CancellationError || (error as? URLError)?.code == .cancelled
}
/// Whether a failed run offers Try Again: only a read-only run (`retryable`; writes never), and never after a 429. The
/// alert then says how long to wait (`rateLimitUserMessage`), and Try Again, its Return default, would resend at once
/// against that advice, possibly extending the block.
func runFailureOffersRetry(_ error: Error, retryable: Bool) -> Bool {
    guard retryable else { return false }
    if case APIError.http(status: 429, _, _, _) = error { return false }
    return true
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
/// Clearing the Orders search reloads only the orders (`applyOrderFilter`) once the account has loaded; before that
/// (or without a key, which opens Settings) it keeps the full refresh.
func orderSearchClearReloadsOnlyOrders(connected: Bool, hasKey: Bool) -> Bool {
    connected && hasKey
}
func shouldUpdateFileIDAfterUpload(uploadedModelID: UUID, selectedLocalID: UUID?) -> Bool {
    selectedLocalID == uploadedModelID
}
/// A file record's own ID (`publicFileServiceId`, `publicId` or `id`), never its name; nil when it has none. Only a
/// non-empty string counts: Slant's upload placeholder carries an internal integer `id` that isn't a file ID, so a
/// reply holding only a number has no file ID (an upload then stays unconfirmed rather than linking to that number).
/// Models' upload, Check Again and Import Orders' personalised uploads all read the ID here.
func uploadedFileID(_ object: [String: Any]) -> String? {
    for key in ["publicFileServiceId", "publicId", "id"] {
        guard let text = object[key] as? String else { continue }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
    }
    return nil
}

// MARK: Upload names

/// The form of a file name the same-name check compares: trimmed, runs of spacing collapsed, any case, and without
/// trailing model extensions (".stl", ".obj" and ".3mf", any number of them, so "Bracket.3mf.stl" matches "Bracket"),
/// but never stripped to nothing: an empty key would match no file. Slant keeps one file per owner and name (an upload
/// whose name matched an earlier one reused that file, 30 Oct 2026), and its exact matching rule is unknown, so this
/// errs towards finding a match.
func slantUploadNameKey(_ name: String) -> String {
    var words = name.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    while ["stl", "obj", "3mf"].contains((words as NSString).pathExtension.lowercased()) {
        let stem = (words as NSString).deletingPathExtension.trimmingCharacters(in: .whitespacesAndNewlines)
        // Each pass shortens the name, so this ends; a name that is all extension keeps its last one.
        guard !stem.isEmpty, stem.count < words.count else { break }
        words = stem
    }
    return words.folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
}

/// The listed Slant file an upload named `name` would share, else nil (also nil for a blank name). Several listed
/// names may match the comparison key; the linked file (`preferredFileID`) wins, then an exact (trimmed) name, then
/// the first listed.
func slantUploadNameConflictRecord(name: String, files: [Record], preferredFileID: String? = nil) -> Record? {
    let key = slantUploadNameKey(name)
    guard !key.isEmpty else { return nil }
    let matches = files.filter { file in
        guard let listed = file.values["name"] as? String else { return false }
        return slantUploadNameKey(listed) == key
    }
    let preferred = preferredFileID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    if !preferred.isEmpty, let linked = matches.first(where: { uploadedFileID($0.values) == preferred }) { return linked }
    let exact = name.trimmingCharacters(in: .whitespacesAndNewlines)
    if let same = matches.first(where: { ($0.values["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) == exact }) {
        return same
    }
    return matches.first
}

/// The name of a listed Slant file that an upload named `name` would share, else nil (also nil for a blank name).
func slantUploadNameConflict(name: String, files: [Record]) -> String? {
    slantUploadNameConflictRecord(name: name, files: files).flatMap { ($0.values["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }
}

/// The first of "Name 2", "Name 3", … that no listed Slant file shares (compared by `slantUploadNameKey`). The name's
/// spacing is tidied; a trailing number is never read as a counter ("Bracket 50" becomes "Bracket 50 2"). A trailing
/// .stl, .obj or .3mf (any case) stays last ("part.3mf" becomes "part 2.3mf"), so the suggestion keeps its type.
func slantUploadUniqueName(name: String, files: [Record]) -> String {
    var base = name.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    var suffix = ""
    let ext = (base as NSString).pathExtension
    if ["stl", "obj", "3mf"].contains(ext.lowercased()) {
        let stem = (base as NSString).deletingPathExtension.trimmingCharacters(in: .whitespacesAndNewlines)
        if !stem.isEmpty { base = stem; suffix = ".\(ext)" }
    }
    let taken = Set(files.compactMap { ($0.values["name"] as? String).map(slantUploadNameKey) })
    var number = 2
    while taken.contains(slantUploadNameKey("\(base) \(number)\(suffix)")) { number += 1 }
    return "\(base) \(number)\(suffix)"
}

/// What the same-name check found before an upload.
enum SlantUploadNameCheck: Equatable {
    /// No listed Slant file has this name: upload it as it is.
    case clear
    /// `existing` is the listed file's name; `suggested` the next free "Name N".
    case conflict(existing: String, suggested: String)
}

func slantUploadNameCheck(name: String, files: [Record]) -> SlantUploadNameCheck {
    slantUploadNameCheckResult(name: name, linkedFileID: nil, files: files).check
}

/// The whole result of the same-name check: what to upload as, what it matched, and the files the pre-PUT guard must
/// protect (`protectedFiles(replacing:)`).
struct SlantUploadNameCheckResult {
    /// The name to upload as: the linked cloud file's name for a linked model when it is listed, else the name given.
    var name: String
    var check: SlantUploadNameCheck
    /// The matching listed file's own ID, when it has one.
    var conflictFileID: String?
    /// The match is the model's linked file: its own earlier upload.
    var conflictIsLinkedFile: Bool
    /// Every file the check read (the fresh list, then the loaded one).
    var files: [Record]

    /// The pre-PUT guard's list: every file read, except the one the seller chose to replace.
    func protectedFiles(replacing: String? = nil) -> [String: String] { uploadProtectedFiles(files, replacing: replacing) }
}

/// The same-name decision. For a model linked to a listed cloud file, the name is that file's, so a model uploaded as
/// "Bracket 2" is checked against "Bracket 2" (its own file), never another model's "Bracket".
func slantUploadNameCheckResult(name: String, linkedFileID: String?, files: [Record]) -> SlantUploadNameCheckResult {
    let linked = linkedFileID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    var uploadName = name.trimmingCharacters(in: .whitespacesAndNewlines)
    if !linked.isEmpty, let file = files.first(where: { uploadedFileID($0.values) == linked }),
       let listed = (file.values["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !listed.isEmpty {
        uploadName = listed
    }
    guard let record = slantUploadNameConflictRecord(name: uploadName, files: files, preferredFileID: linked),
          let existing = (record.values["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) else {
        return SlantUploadNameCheckResult(name: uploadName, check: .clear, conflictFileID: nil, conflictIsLinkedFile: false, files: files)
    }
    let conflictID = uploadedFileID(record.values)
    return SlantUploadNameCheckResult(
        name: uploadName,
        check: .conflict(existing: existing, suggested: slantUploadUniqueName(name: uploadName, files: files)),
        conflictFileID: conflictID,
        conflictIsLinkedFile: !linked.isEmpty && conflictID == linked,
        files: files)
}

/// The confirmation shown when an upload's name is already in the seller's Slant files. `ownEarlierUpload`: the match
/// is the selected model's linked file. `earlierUploadUnconfirmed`: Slant didn't confirm this model's last upload, so
/// the match may be that upload. Whether placed orders are affected is unverified, hence "possibly".
func slantUploadNameConflictMessage(existing: String, ownEarlierUpload: Bool = false, earlierUploadUnconfirmed: Bool = false) -> String {
    var text = "A file named “\(existing)” is already in your Slant files."
    if ownEarlierUpload {
        text += " It’s this model’s earlier upload."
    } else if earlierUploadUnconfirmed {
        text += " Slant didn’t confirm this model’s earlier upload, so this may be that upload."
    }
    return text + " Uploading with this name replaces that file for every draft that uses it, and possibly for orders not yet printed."
}

/// Upload Again… when the same-name check found no file with the model's name: the one question before uploading.
func reuploadNoConflictMessage(name: String, earlierUploadUnconfirmed: Bool) -> String {
    let lead = earlierUploadUnconfirmed
        ? "Slant didn’t confirm the earlier upload of “\(name)”, and no file with this name is in your Slant files now."
        : "No file named “\(name)” is in your Slant files now."
    return "\(lead) This uploads it as a new file, and this Mac’s copy will link to it."
}

/// The other library models linked (trimmed) to one of `fileIDs`.
func modelsLinked(toFileIDs fileIDs: Set<String>, in models: [LocalModel]) -> Set<UUID> {
    guard !fileIDs.isEmpty else { return [] }
    return Set(models.filter { model in
        guard let id = model.remoteID?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty else { return false }
        return fileIDs.contains(id)
    }.map(\.id))
}

// MARK: Putting links back after a Replace File that sent nothing

/// What a Replace File's unlinking before sending changed (`clearLinksBeforeReplacing`), so that a Models Replace File
/// that stopped before any bytes could be sent can put it back (`restoreLinksAfterReplaceSentNothing`).
struct ReplaceFileClearedLinks: Equatable {
    /// The file the seller chose to replace, as passed to the unlinking (trimmed).
    var replacedFileID: String
    /// Each unlinked model's link exactly as it was stored, non-blank only (`replaceFileClearedLinks`).
    var links: [UUID: String]
    /// The names of the other models unlinked, in library order; the uploaded model is never among them.
    var otherNames: [String]
    /// The IDs the unlinking added to the library's changed files (none when the file was already recorded as changed).
    var addedChangedFileIDs: Set<String>
    /// The uploader records (file ID → model) the unlinking removed.
    var removedUploaders: [String: UUID]
    /// The selected library model and Slant file when the links were cleared.
    var selectedLocalID: UUID?
    var selectedFileID: String
}

/// The links a Replace File's unlinking clears (`clearLinks` with the replaced file and the uploaded model): every model
/// linked (trimmed, through `modelsLinked`, as `clearLinks` matches) to `replacedFileID`, and the uploaded model
/// whatever file it links (its own earlier upload may be under another name), each link as stored. Blank links are
/// left out: there is nothing to put back.
func replaceFileClearedLinks(models: [LocalModel], replacedFileID: String, uploadedModelID: UUID?) -> [UUID: String] {
    let affected = modelsLinked(toFileIDs: [replacedFileID], in: models)
    var links: [UUID: String] = [:]
    for model in models where affected.contains(model.id) || model.id == uploadedModelID {
        guard let link = model.remoteID, !link.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
        links[model.id] = link
    }
    return links
}

/// The cleared links that come back after a Replace File that sent nothing: only for a model still in the library and
/// still unlinked, and only when no library model links that file now (trimmed), so the restore never makes a new
/// shared link. Models that shared the file before (a Download a Separate Copy pair) all come back together, as they were.
func replaceFileLinksToRestore(_ cleared: [UUID: String], models: [LocalModel]) -> [UUID: String] {
    let trim: (String?) -> String = { ($0 ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
    let linkedNow = Set(models.map { trim($0.remoteID) }.filter { !$0.isEmpty })
    let unlinkedNow = Set(models.filter { trim($0.remoteID).isEmpty }.map(\.id))
    return cleared.filter { id, link in
        unlinkedNow.contains(id) && !linkedNow.contains(trim(link))
    }
}

/// The names, in library order, of the models a Replace File unlinked that stay unlinked: still in the library and
/// still unlinked, but not in `restoring`. A model removed meanwhile isn't named.
func replaceFileModelsLeftUnlinked(_ cleared: [UUID: String], restoring: [UUID: String], models: [LocalModel]) -> [String] {
    models.filter { model in
        cleared[model.id] != nil && restoring[model.id] == nil
            && (model.remoteID ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }.map(\.name)
}

/// The selected Slant file (`fileID`) after a Replace File that sent nothing put links back, or nil to leave it as it
/// is. While `fileID` is blank: a selected library model whose link came back selects that link again (as selecting it
/// would); with no library model selected, as when the links were cleared, the replaced file selected then (a Slant
/// file chosen in the list) is selected again. A selection that moved meanwhile is left alone.
func replaceFileSelectedFileAfterRestore(selectedLocalID: UUID?, fileID: String, restored: [UUID: String],
                                         clearedSelection: (localID: UUID?, fileID: String),
                                         replacedFileID: String) -> String? {
    guard fileID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
    if let selected = selectedLocalID { return restored[selected] }
    guard clearedSelection.localID == nil else { return nil }
    let earlier = clearedSelection.fileID.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !earlier.isEmpty, earlier == replacedFileID.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
    return clearedSelection.fileID
}

/// Leads the note when the links a Replace File cleared couldn't be put back because the library couldn't be saved.
/// `saveModels`' own alert, with its disk-space advice, is replaced by the upload's failure message, so this gives the
/// advice. The sentence after it (`uploadReplacementUnlinkedNote`) names the `modelCount` models, so the two agree.
func uploadReplacementRestoreNotSavedNote(modelCount: Int) -> String {
    let models = modelCount == 1 ? "this model" : "these models"
    return "Plinth couldn’t save your library (check that your Mac has free disk space), so it couldn’t link \(models) again."
}

/// Added to a Models Replace File's failure copy after a stop before any bytes could be sent: nil when every cleared
/// link came back (the failure copy already says nothing was uploaded), else `uploadReplacementUnlinkedNote` naming the
/// models left unlinked, led by `uploadReplacementRestoreNotSavedNote` when the restore couldn't be saved.
func uploadReplacementRestoreNote(fileName: String, leftUnlinked: [String], restoreNotSaved: Bool) -> String? {
    let note = uploadReplacementUnlinkedNote(fileName: fileName, modelNames: leftUnlinked)
    guard restoreNotSaved else { return note }
    return [uploadReplacementRestoreNotSavedNote(modelCount: leftUnlinked.count), note].compactMap { $0 }.joined(separator: " ")
}

/// Whether a `GET /files` page can be used for the same-name check: a list (empty is fine), and when it has rows, at
/// least one names its file. A reply in another shape could hide a name, so it stops the upload instead.
func slantFileNamePageIsReadable(_ json: Any?) -> Bool {
    guard let root = json as? [String: Any] else { return false }
    let rows: [Any]
    if let list = root["data"] as? [Any] { rows = list }
    else if let data = root["data"] as? [String: Any], let list = data["files"] as? [Any] { rows = list }
    else { return false }
    let records = rows.compactMap { $0 as? [String: Any] }
    guard records.count == rows.count else { return false }
    return records.isEmpty || records.contains { $0["name"] is String }
}

/// The most pages of 100 the same-name check reads (5,000 files).
let slantUploadNameCheckMaxPages = 50

/// How to try the check again, where it was started: Models' upload buttons, or the Upload from URL sheet's Upload.
let slantUploadNameCheckRetryInModels = "Upload again to check once more."
let slantUploadNameCheckRetryInURLSheet = "Press Upload to try again."

/// Why nothing was uploaded when the same-name check couldn't read the whole file list.
func slantUploadNameCheckFailedMessage(name: String, reason: String, retryHint: String = slantUploadNameCheckRetryInModels) -> String {
    let lead = "Plinth couldn’t read all your Slant files to check for one already named “\(name)”, so nothing was uploaded."
    let trimmed = reason.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? "\(lead) \(retryHint)" : "\(lead) \(trimmed) \(retryHint)"
}

/// The same-name check stopped for the rate limit (`slantUploadNameCheckRateLimitStop`, or a 429 to its read).
struct SlantUploadNameCheckRateLimited: Error {}
let slantUploadNameCheckRateLimitedMessage = "Slant’s rate limit is nearly used up, so Plinth didn’t check your Slant files and nothing was uploaded. Wait a minute, then upload again."

/// The account lists more files than the check reads; refreshing can't help.
struct SlantUploadNameCheckTooManyFiles: Error {}
let slantUploadNameCheckTooManyFilesMessage = "Your Slant account lists more than \((slantUploadNameCheckMaxPages * listPageSize).formatted()) files. Plinth checks every file’s name before an upload and can’t check that many, so nothing was uploaded."

/// Whether the same-name check's next page read must stop: until a 429's wait has passed, or while Studio's known
/// allowance is at or below the order watch's reserve (`orderWatchRateLimitReserve`). A low count with a reset time
/// holds until that time; without one it is trusted for a minute after it was seen.
func slantUploadNameCheckRateLimitStop(rateLimit: RateLimitInfo?, observedAt: Date?, rateLimitedUntil: Date?, now: Date) -> Bool {
    if let until = rateLimitedUntil, until > now { return true }
    guard let rateLimit, let remaining = rateLimit.remaining, remaining <= orderWatchRateLimitReserve else { return false }
    if let reset = rateLimit.reset { return reset > now }
    guard let observedAt else { return false }
    return now.timeIntervalSince(observedAt) < 60
}

/// The other library models linked to `fileID` once `uploadedModelID` has been linked to it. Slant stored the upload
/// in a file they were linked to, so that file now holds the uploaded model and only the uploaded model keeps the link.
func modelsLosingLinkAfterUpload(fileID: String, uploadedModelID: UUID?, in models: [LocalModel]) -> [UUID] {
    let trimmed = fileID.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return [] }
    return models.filter {
        $0.id != uploadedModelID && $0.remoteID?.trimmingCharacters(in: .whitespacesAndNewlines) == trimmed
    }.map(\.id)
}

/// The titles of the alert after an upload: Slant stored it in a file other library models were linked to, or a
/// Replace File went into another file than the one chosen (`uploadReplaceSavedElsewhereNotice`).
let uploadLinkMovedAlertTitle = "Slant saved this upload in an existing file"
let uploadReplaceSavedElsewhereAlertTitle = "Slant didn’t replace the file you chose"

/// The notice after an upload took over a file other library models were linked to; nil when none were.
func uploadLinkMovedNotice(uploadedName: String, otherNames: [String]) -> String? {
    guard let first = otherNames.first else { return nil }
    if otherNames.count == 1 {
        return "Slant saved “\(uploadedName)” in the same file as “\(first)”, so that file now holds “\(uploadedName)”. “\(first)” is no longer linked to a Slant file; upload it again before using it in an order."
    }
    return "Slant saved “\(uploadedName)” in the same file as \(otherNames.count) other models in your library, so that file now holds “\(uploadedName)”. Those models are no longer linked to a Slant file; upload them again before using them in an order."
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
/// Upload from URL's copy after a Replace File whose outcome is unclear: the replaced file may now hold the link's
/// model, and `modelNames` (the library models that were linked to it) are no longer linked.
func uploadFromURLReplaceUnclearMessage(_ error: Error, fileName: String, modelNames: [String]) -> String {
    let trimmed = fileName.trimmingCharacters(in: .whitespacesAndNewlines)
    let file = trimmed.isEmpty ? "the existing file in your Slant files" : "your Slant file “\(trimmed)”"
    var text = "\(slantUnclearReplyCause(error)), so \(file) may now hold this model, or part of it, for every draft that uses it."
    if let first = modelNames.first {
        text += modelNames.count == 1
            ? " “\(first)” was linked to that file and no longer is; upload it again before you use it in an order."
            : " \(modelNames.count) models in your library were linked to that file and no longer are; upload them again before you use them in an order."
    }
    return text + " Refresh in the main window to see what Slant now lists."
}
/// The title of the notice after an Upload from URL Replace File that Slant accepted without naming a file.
let uploadFromURLNoFileIDAlertTitle = "Slant didn’t say which file it used"
/// The notice after an Upload from URL Replace File that Slant accepted without naming the file it used: the models
/// unlinked before sending stay unlinked (`uploadReplacementUnlinkedNote`). Nil when none were.
func uploadFromURLReplaceNoFileIDNotice(uploadedName: String, fileName: String, unlinkedNames: [String]) -> String? {
    guard let note = uploadReplacementUnlinkedNote(fileName: fileName, modelNames: unlinkedNames) else { return nil }
    return "Slant took “\(uploadedName)” but didn’t say which of your Slant files holds it. \(note)"
}
/// Create Platform's copy when Slant may have made the platform anyway, else nil.
func platformCreateUnclearMessage(_ error: Error) -> String? {
    guard slantCreateOutcomeUnclear(error) else { return nil }
    return "\(slantUnclearReplyCause(error)), so the platform may already exist. Use Refresh Platforms in Settings › Account to check before creating it again."
}
/// The file ID Slant's upload placeholder named (`uploadPlaceholderFileID`), set from `APIClient.upload`'s check.
final class UploadTargetBox: @unchecked Sendable {
    private let lock = NSLock()
    private var id: String?
    var value: String? {
        get { lock.lock(); defer { lock.unlock() }; return id }
        set { lock.lock(); id = newValue; lock.unlock() }
    }
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
/// Try Again's action for the main window's error alert. `run` sets it after a failed retryable run and clears it on
/// every other outcome, OK clears it, and `retryLast()` takes it, so it runs at most once. The alert's closing doesn't
/// clear it (`errorAlertClosed`), because SwiftUI may report that before the button's queued retry runs.
struct ErrorRetrySlot {
    private(set) var action: StudioStore.RetryAction?
    mutating func set(_ action: StudioStore.RetryAction) { self.action = action }
    mutating func clear() { action = nil }
    mutating func take() -> StudioStore.RetryAction? {
        defer { action = nil }
        return action
    }
}
func encodedSegment(_ string: String) -> String { string.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-_"))) ?? "" }
