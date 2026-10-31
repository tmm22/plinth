import Foundation
import SwiftUI
import Combine

// Which print service the seller works with: Slant 3D (the default, everything Plinth has always done) or 3DAPI
// (dapi.digital), which offers the same workflows where its API allows. The choice is the only new preference; the
// services never share data (no Slant price, ID or file reaches 3DAPI, and none of 3DAPI's reaches Slant).

/// The print service the Models next-action bar, the Orders section and Catalog's materials work with.
enum PrintService: String, CaseIterable, Identifiable, Sendable {
    case slant
    case dapi

    var id: String { rawValue }

    /// The service's name in copy ("Slant 3D", "3DAPI").
    var displayName: String {
        switch self {
        case .slant: "Slant 3D"
        case .dapi: "3DAPI"
        }
    }

    /// The UserDefaults key holding the raw value; absent or unknown means Slant.
    static let defaultsKey = "printService"

    /// The saved choice, Slant when none is saved or the saved value is unknown.
    static func saved(in defaults: UserDefaults = .standard) -> PrintService {
        defaults.string(forKey: defaultsKey).flatMap(PrintService.init(rawValue:)) ?? .slant
    }
}

/// The seller's current print service, shared by the main window and Settings. Changing it is refused while either
/// service has a write waiting for its reply or an order sheet is open (`printServiceChangeBlockedReason`, computed by
/// Settings), so a running order never loses the screen that reports its outcome.
@MainActor final class PrintServiceChoice: ObservableObject {
    static let shared = PrintServiceChoice()

    @Published private(set) var service: PrintService
    private let defaults: UserDefaults
    /// Set once the main window starts coordinating the 3DAPI order watch (`startCoordinatingDapiOrderWatch`).
    private var orderWatchSubscription: AnyCancellable?
    private var lastOrderWatchCoordination: DapiOrderWatchCoordination?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        service = PrintService.saved(in: defaults)
    }

    /// Switches to `service` unless `blockedReason` (computed by the caller from both services' state) says why not;
    /// returns that reason, or nil once switched.
    @discardableResult
    func select(_ service: PrintService, blockedReason: String?) -> String? {
        guard service != self.service else { return nil }
        if let blockedReason { return blockedReason }
        self.service = service
        defaults.set(service.rawValue, forKey: PrintService.defaultsKey)
        return nil
    }

    /// Keeps the 3DAPI order watch running exactly while 3DAPI is the print service and a 3DAPI key is saved: at
    /// launch (the first call), whenever the service changes and whenever the key is saved, replaced or removed (a
    /// replaced key restarts it from nothing, since the new key may belong to another account; see
    /// `dapiOrderWatchActivations`). Idempotent; called once the main window appears, so preferences are read only
    /// after the move from Slant Studio.
    func startCoordinatingDapiOrderWatch() {
        guard orderWatchSubscription == nil else { return }
        let connection = DapiConnection.shared
        let watch = DapiOrderWatch.shared
        // @Published sends each new value before the property changes, so only the values passed in are used.
        orderWatchSubscription = $service.combineLatest(connection.$isConfigured, connection.$keyGeneration)
            .map { DapiOrderWatchCoordination(active: dapiOrderWatchShouldBeActive(service: $0, dapiKeySaved: $1), keyGeneration: $2) }
            .removeDuplicates()
            .sink { [weak self] next in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    let calls = dapiOrderWatchActivations(from: self.lastOrderWatchCoordination, to: next)
                    self.lastOrderWatchCoordination = next
                    for active in calls { watch.setActive(active) }
                }
            }
    }
}

/// Whether the 3DAPI order watch should run: only while 3DAPI is the print service and its key is saved.
func dapiOrderWatchShouldBeActive(service: PrintService, dapiKeySaved: Bool) -> Bool {
    service == .dapi && dapiKeySaved
}

/// What the 3DAPI order watch coordination last saw: whether the watch should run, and the key generation
/// (`DapiConnection.keyGeneration`).
struct DapiOrderWatchCoordination: Equatable {
    let active: Bool
    let keyGeneration: Int
}

/// The `setActive` calls for a change, in order: the first value sets the watch's state; a change of `active` sets
/// it; a new key generation while the watch stays active stops it (forgetting the earlier key's orders and any pause
/// after a refused key) and starts it again; anything else changes nothing.
func dapiOrderWatchActivations(from previous: DapiOrderWatchCoordination?, to next: DapiOrderWatchCoordination) -> [Bool] {
    guard let previous else { return [next.active] }
    if previous.active != next.active { return [next.active] }
    if next.active, previous.keyGeneration != next.keyGeneration { return [false, true] }
    return []
}

// MARK: - Switching services

/// Why the print service can't change now, or nil. A switch replaces the Orders screen and Models' next steps, so it
/// waits while either service has a write waiting for its reply (whose outcome the screen reports), a 3DAPI order sheet
/// is open, a Slant request runs, the Get 3DAPI quote sheet or any other sheet, alert or dialog is shown in any window
/// (a Slant pay or cancel review among them), or a 3DAPI request is still working.
func printServiceChangeBlockedReason(dapiOrderSessionReason: String?, writesInFlight: [SlantWriteKind], slantBusy: Bool,
                                     modalUIShown: Bool, dapiRequestsRunning: Int, dapiQuoteSheetsOpen: Int,
                                     dapiQuoteWritesInFlight: Int) -> String? {
    if let dapiOrderSessionReason { return dapiOrderSessionReason }
    if writesInFlight.contains(where: { $0.service == .dapi }) { return "Wait for 3DAPI to answer the order or cancellation first." }
    if !writesInFlight.isEmpty { return "Wait for Slant to answer the request that’s still waiting first." }
    if slantBusy { return "Wait for the current request to finish." }
    if dapiQuoteSheetsOpen > 0 { return "Close the Get 3DAPI quote sheet first." }
    if modalUIShown { return "Close the open sheet, alert or dialog first." }
    if dapiRequestsRunning > 0 || dapiQuoteWritesInFlight > 0 { return "Wait for the 3DAPI request to finish." }
    return nil
}

/// Settings › Account › Print service's footer.
let printServiceSettingsFooter = "Choose who prints your orders. This changes Models’ next steps, the Orders section and Catalog’s materials; your model library and Get 3DAPI Quote… stay as they are. The two services never share data: no price, ID or file from one is sent to the other."

/// Shown under the picker while 3DAPI is chosen without a saved 3DAPI key.
let printServiceDapiKeyMissingNote = "Add your 3DAPI integrator key under 3DAPI below to quote and order with 3DAPI."

/// Settings › Account's first section: the print service picker. A change goes through
/// `PrintServiceChoice.select(_:blockedReason:)` with the reason computed at the moment of the change.
struct PrintServiceSettingsSection: View {
    @EnvironmentObject var store: StudioStore
    @EnvironmentObject var modalPresentation: ModalPresentationMonitor
    @ObservedObject private var choice = PrintServiceChoice.shared
    @ObservedObject private var dapi = DapiConnection.shared
    @ObservedObject private var dapiOrders = DapiOrderSession.shared
    @State private var refusal: String?

    /// From published state, for the disabled look; `blockedNow` is checked when the seller picks.
    private var blocked: String? {
        printServiceChangeBlockedReason(
            dapiOrderSessionReason: dapiOrders.changeBlockedReason, writesInFlight: [], slantBusy: store.busy,
            modalUIShown: store.isPresentingSheet || modalPresentation.isPresenting,
            dapiRequestsRunning: dapi.activeRequests, dapiQuoteSheetsOpen: dapi.openSheets,
            dapiQuoteWritesInFlight: dapi.quoteWritesInFlight.count)
    }

    private var blockedNow: String? {
        printServiceChangeBlockedReason(
            dapiOrderSessionReason: DapiOrderSession.shared.changeBlockedReason,
            writesInFlight: SlantWritesInFlight.shared.kinds, slantBusy: store.busy,
            modalUIShown: store.isPresentingSheet || appIsPresentingModalUI(),
            dapiRequestsRunning: dapi.activeRequests, dapiQuoteSheetsOpen: dapi.openSheets,
            dapiQuoteWritesInFlight: dapi.quoteWritesInFlight.count)
    }

    var body: some View {
        Section {
            Picker("Print service", selection: Binding(get: { choice.service }, set: { pick($0) })) {
                ForEach(PrintService.allCases) { service in
                    Text(service.displayName).tag(service)
                }
            }
            .disabled(blocked != nil)
            .help(blocked ?? "Choose the print service for Models, Orders and Catalog")
            if let blocked {
                Text(blocked).font(.caption).foregroundStyle(.secondary)
            } else if let refusal {
                Label(refusal, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
            }
            if choice.service == .dapi, !dapi.isConfigured {
                Label(printServiceDapiKeyMissingNote, systemImage: "key")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } header: {
            Text("Print service")
        } footer: {
            Text(printServiceSettingsFooter).settingsFooterLayout()
        }
    }

    private func pick(_ service: PrintService) {
        refusal = choice.select(service, blockedReason: blockedNow)
    }
}

// MARK: - Main window rules

/// The Connect Slant Account prompt replaces a screen that can't work without a Slant key. With 3DAPI as the print
/// service, Orders and Catalog are 3DAPI's (they explain a missing 3DAPI key themselves) and Models works offline, so
/// the Slant prompt never shows.
func showsConnectAccountPrompt(destination: Destination, hasKey: Bool, hasLocalModels: Bool, service: PrintService) -> Bool {
    guard service == .slant else { return false }
    return showsConnectAccountPrompt(destination: destination, hasKey: hasKey, hasLocalModels: hasLocalModels)
}

/// The sidebar's Orders badge: the chosen service's order watch only.
func ordersSidebarBadgeCount(service: PrintService, slantCount: Int, dapiCount: Int) -> Int {
    service == .dapi ? dapiCount : slantCount
}

/// Whether the toolbar (and File › Refresh) offers Slant's Refresh. With 3DAPI chosen, Models, Orders and Catalog
/// show 3DAPI (Orders reloads itself), so only the Slant developer screens keep it.
func slantRefreshAvailable(service: PrintService, destination: Destination) -> Bool {
    service == .slant || destination.isDeveloperDestination
}

/// Whether the File menu's Slant order commands are Slant's: only while Slant is the print service. With 3DAPI,
/// Upload from URL… and Import Orders… are disabled (3DAPI has no URL import, and every 3DAPI order is charged when
/// placed), while Export Orders…, Tracking for Your Shop… and Spending Report… do 3DAPI's versions
/// (`dapiOrderToolMenuEnabled`). The Models toolbar's Upload from URL… follows the same rule.
func slantOrderMenuCommandsAvailable(service: PrintService) -> Bool { service == .slant }

/// File › New Order Draft…'s title: 3DAPI has no drafts, so with 3DAPI it opens the order composer.
func newOrderMenuTitle(service: PrintService) -> String {
    service == .dapi ? "New 3DAPI Order…" : "New Order Draft…"
}

/// Whether the last account check says the saved 3DAPI key can place orders.
func dapiCanOrder(keySaved: Bool, account: DapiAccount?, onboarding: DapiOnboarding?) -> Bool {
    guard keySaved, let account, dapiAccountProblem(account) == nil else { return false }
    return dapiOrderingProblem(account: account, onboardingOrderBlockers: onboarding?.orderBlockers ?? []) == nil
}

/// The sidebar footer's status while 3DAPI is the print service. Before the first account check this session, a saved
/// key is only "Key saved".
func dapiConnectionFooterStatus(keySaved: Bool, account: DapiAccount?, onboarding: DapiOnboarding?) -> String {
    guard keySaved else { return "3DAPI · No key" }
    guard let account else { return "3DAPI · Key saved" }
    if dapiAccountProblem(account) != nil { return "3DAPI · Key can’t be used" }
    return dapiCanOrder(keySaved: keySaved, account: account, onboarding: onboarding) ? "Connected to 3DAPI" : "3DAPI · Quotes only"
}

/// The sidebar footer's status while Slant is the print service (`connectionFooterStatus`), naming Slant when the
/// status doesn't already.
func slantConnectionFooterStatus(_ status: String) -> String {
    status.contains("Slant") ? status : "Slant 3D · \(status)"
}

// MARK: - Models' next steps with 3DAPI

/// The Models next-action bar's step while 3DAPI is the print service.
enum DapiModelsNextStep: Equatable {
    case needsModel, needsLocalCopy, fileMissing, needsKey, invalidQuantity, ready
}

/// 3DAPI quotes and prints files from this Mac, so an uploaded Slant model needs a local copy first.
func dapiModelsNextStep(hasSelection: Bool, selectedIsLocal: Bool, localFileExists: Bool, keySaved: Bool,
                        quantityValid: Bool) -> DapiModelsNextStep {
    if !hasSelection { return .needsModel }
    if !selectedIsLocal { return .needsLocalCopy }
    if !localFileExists { return .fileMissing }
    if !keySaved { return .needsKey }
    if !quantityValid { return .invalidQuantity }
    return .ready
}

/// Which button the ready bar makes prominent, mirroring Slant's step order (estimate, then order): Get 3DAPI Quote…
/// until this session knows a ready quote for the model's file, then Order with 3DAPI…, unless the last account check
/// says ordering is blocked (then no button is prominent; Order with 3DAPI…'s help says why).
enum DapiModelsPrimaryAction: Equatable {
    case getQuote, order, none
}

func dapiModelsPrimaryAction(hasReadyQuote: Bool, orderingProblem: String?) -> DapiModelsPrimaryAction {
    guard hasReadyQuote else { return .getQuote }
    return orderingProblem == nil ? .order : .none
}

/// Order with 3DAPI…'s help: why ordering is blocked, when the account check says so.
func dapiOrderButtonHelp(orderingProblem: String?) -> String {
    if let orderingProblem { return orderingProblem }
    return "Opens the 3DAPI order composer in Orders. Nothing is charged until you review the order and press Place Order."
}

/// The ready bar's status line once the file's quote state is known (`hasReadyQuote`); `orderingProblem` comes first.
func dapiModelsReadyStatus(hasReadyQuote: Bool, orderingProblem: String?) -> String {
    if let orderingProblem { return orderingProblem }
    if hasReadyQuote {
        return "3DAPI has quoted this model. Order it with 3DAPI: nothing is charged until you review the order and press Place Order."
    }
    return "Get a 3DAPI quote first, then order it with 3DAPI. Nothing is charged until you review the order and press Place Order."
}

/// The bar's status line for a 3DAPI step: the ready line is `dapiModelsReadyStatus` (where `orderingProblem`, from
/// the last account check, replaces it; Get 3DAPI Quote… still works without ordering).
func dapiModelsNextStepStatus(_ step: DapiModelsNextStep, hasReadyQuote: Bool = false, orderingProblem: String?) -> String {
    switch step {
    case .needsModel: return "Import a model to quote and order it with 3DAPI."
    case .needsLocalCopy: return "3DAPI prints models from this Mac. Download this model into the library first."
    case .fileMissing: return "This model’s file is missing from the library, so 3DAPI can’t quote or print it. Import it again."
    case .needsKey: return "Add your 3DAPI integrator key in Settings › Account to quote and order with 3DAPI."
    case .invalidQuantity: return "Enter a whole-number quantity from 1 to 10,000."
    case .ready: return dapiModelsReadyStatus(hasReadyQuote: hasReadyQuote, orderingProblem: orderingProblem)
    }
}

/// The 3DAPI composer's starting point for Order with 3DAPI….
func dapiOrderPrefill(modelID: UUID, quantity: Int) -> DapiComposerPrefill {
    DapiComposerPrefill(modelID: modelID, quantity: min(max(quantity, 1), 10_000), countryCode: nil)
}

/// Order a Sample to Me… with 3DAPI: one of the model, to the seller's own saved address, for review in the composer.
func dapiSampleOrderPrefill(modelID: UUID) -> DapiComposerPrefill {
    DapiComposerPrefill(modelID: modelID, quantity: 1, countryCode: nil, useSellerAddress: true)
}

/// What asking for the 3DAPI composer does (New 3DAPI Order…, Order with 3DAPI…, Order a Sample to Me…).
enum DapiComposerOpening: Equatable {
    /// Nothing: Slant is the print service, or something modal is shown.
    case ignore
    /// No 3DAPI key is saved: Settings › Account opens instead, and no composer request is left waiting.
    case openSettings
    case openComposer
}

func dapiComposerOpening(service: PrintService, keySaved: Bool, modalUIShown: Bool) -> DapiComposerOpening {
    guard service == .dapi, !modalUIShown else { return .ignore }
    return keySaved ? .openComposer : .openSettings
}

/// Whether File › Export Orders…, Tracking for Your Shop…, Spending Report… (and Refresh) perform their 3DAPI versions:
/// only while 3DAPI is the print service with a key saved and nothing modal is shown. Each only reads or opens a sheet
/// in 3DAPI's Orders (`DapiOrderToolRequest`); none sends a write. `ordersLoaded` is
/// `DapiOrderListState.hasRowsForTools` (rows read for the filter shown).
func dapiOrderToolMenuEnabled(_ tool: DapiOrderToolRequest, service: PrintService, keySaved: Bool, destination: Destination,
                              modalUIShown: Bool, ordersLoaded: Bool) -> Bool {
    guard service == .dapi, keySaved, !modalUIShown else { return false }
    switch tool {
    case .reload:
        // Refresh reloads what is shown: on Models and Catalog there is no 3DAPI list to reload (and the developer
        // screens keep Slant's Refresh, `slantRefreshAvailable`).
        return destination == .orders
    case .exportOrders, .trackingForYourShop:
        // Like the Orders toolbar's Tools menu: they work on the orders listed, so only with Orders shown and rows read.
        return destination == .orders && ordersLoaded
    case .spendingReport:
        // Reads its own period (Load the Whole Period), so it opens from anywhere.
        return true
    }
}

extension StudioStore {
    /// Opens the 3DAPI order composer in Orders with `prefill`. Only while 3DAPI is the print service and nothing modal
    /// is shown; nothing is sent (the composer reviews the order, and only Place Order there sends it). Without a saved
    /// 3DAPI key it opens Settings › Account instead, so no request is left queued for a composer that can't open.
    func openDapiComposer(_ prefill: DapiComposerPrefill) {
        switch dapiComposerOpening(service: PrintServiceChoice.shared.service, keySaved: DapiConnection.shared.isConfigured,
                                   modalUIShown: isPresentingSheet || appIsPresentingModalUI()) {
        case .ignore:
            return
        case .openSettings:
            requestSettings(.account)
        case .openComposer:
            DapiOrderSession.shared.composerRequest = prefill
            destination = .orders
        }
    }

    /// File › Export Orders…, Tracking for Your Shop…, Spending Report… and Refresh while 3DAPI is the print service:
    /// shows Orders and asks 3DAPI's Orders section to do it (`DapiOrderSession.toolRequest`). Nothing while anything
    /// modal is shown.
    func performDapiOrderToolFromMenu(_ tool: DapiOrderToolRequest) {
        guard dapiOrderToolMenuEnabled(tool, service: PrintServiceChoice.shared.service, keySaved: DapiConnection.shared.isConfigured,
                                       destination: destination, modalUIShown: menuCommandsBlockedByModalUI,
                                       ordersLoaded: DapiOrderListState.shared.hasRowsForTools) else { return }
        destination = .orders
        DapiOrderSession.shared.toolRequest = tool
    }
}
