import XCTest
@testable import Plinth

/// The print service choice (PrintService.swift) and the rules that branch on it: the saved preference, switching and
/// what blocks it, the connect prompt, the sidebar, the menus, Models' 3DAPI next steps and the 3DAPI catalogue.
@MainActor
final class PrintServiceTests: XCTestCase {
    private var suite = ""
    private var defaults: UserDefaults!

    override func setUp() async throws {
        suite = testDefaultsSuiteName("PrintServiceTests")
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() async throws {
        removeTestDefaultsSuite(defaults, named: suite)
    }

    // MARK: Saved preference

    func testSavedPreferenceDefaultsToSlant() {
        XCTAssertEqual(PrintService.saved(in: defaults), .slant, "nothing saved")
        defaults.set("dapi", forKey: PrintService.defaultsKey)
        XCTAssertEqual(PrintService.saved(in: defaults), .dapi)
        for unknown in ["DAPI", "3dapi", "", "slant3d"] {
            defaults.set(unknown, forKey: PrintService.defaultsKey)
            XCTAssertEqual(PrintService.saved(in: defaults), .slant, "an unknown value (\(unknown)) means Slant")
        }
        defaults.set(42, forKey: PrintService.defaultsKey)
        XCTAssertEqual(PrintService.saved(in: defaults), .slant, "a value of the wrong type means Slant")
        defaults.set("dapi", forKey: PrintService.defaultsKey)
        XCTAssertEqual(PrintServiceChoice(defaults: defaults).service, .dapi, "the choice starts from the saved value")
    }

    func testSelectSwitchesAndSavesOnlyWithoutABlockedReason() {
        let choice = PrintServiceChoice(defaults: defaults)
        XCTAssertEqual(choice.service, .slant)

        let refused = choice.select(.dapi, blockedReason: "Close the open sheet, alert or dialog first.")
        XCTAssertEqual(refused, "Close the open sheet, alert or dialog first.")
        XCTAssertEqual(choice.service, .slant)
        XCTAssertNil(defaults.string(forKey: PrintService.defaultsKey), "a refused switch saves nothing")

        XCTAssertNil(choice.select(.dapi, blockedReason: nil))
        XCTAssertEqual(choice.service, .dapi)
        XCTAssertEqual(defaults.string(forKey: PrintService.defaultsKey), "dapi")
        XCTAssertEqual(PrintServiceChoice(defaults: defaults).service, .dapi, "kept across launches")

        // Choosing the current service is never refused and changes nothing.
        XCTAssertNil(choice.select(.dapi, blockedReason: "Wait for the current request to finish."))
        XCTAssertEqual(choice.service, .dapi)

        XCTAssertNil(choice.select(.slant, blockedReason: nil))
        XCTAssertEqual(defaults.string(forKey: PrintService.defaultsKey), "slant")
        // The choice is the only preference it writes.
        XCTAssertEqual(Set((defaults.persistentDomain(forName: suite) ?? [:]).keys), [PrintService.defaultsKey])
    }

    // MARK: What blocks a switch

    private func blocked(dapiOrderSessionReason: String? = nil, writes: [SlantWriteKind] = [], busy: Bool = false,
                         modal: Bool = false, dapiRequests: Int = 0, quoteSheets: Int = 0, quoteWrites: Int = 0) -> String? {
        printServiceChangeBlockedReason(dapiOrderSessionReason: dapiOrderSessionReason, writesInFlight: writes, slantBusy: busy,
                                        modalUIShown: modal, dapiRequestsRunning: dapiRequests,
                                        dapiQuoteSheetsOpen: quoteSheets, dapiQuoteWritesInFlight: quoteWrites)
    }

    func testChangeBlockedReasonComposition() {
        XCTAssertNil(blocked(), "nothing running, nothing shown")
        XCTAssertEqual(blocked(dapiOrderSessionReason: "Close the 3DAPI order sheet first."), "Close the 3DAPI order sheet first.")
        XCTAssertEqual(blocked(writes: [.dapiOrder]), "Wait for 3DAPI to answer the order or cancellation first.")
        XCTAssertEqual(blocked(writes: [.dapiCancellation]), "Wait for 3DAPI to answer the order or cancellation first.")
        for kind in SlantWriteKind.allCases where kind.service == .slant {
            XCTAssertEqual(blocked(writes: [kind]), "Wait for Slant to answer the request that’s still waiting first.", "\(kind)")
        }
        XCTAssertEqual(blocked(busy: true), "Wait for the current request to finish.")
        XCTAssertEqual(blocked(modal: true), "Close the open sheet, alert or dialog first.", "a Slant review, or any sheet")
        XCTAssertEqual(blocked(quoteSheets: 1), "Close the Get 3DAPI quote sheet first.")
        XCTAssertEqual(blocked(modal: true, quoteSheets: 1), "Close the Get 3DAPI quote sheet first.", "the more specific reason")
        XCTAssertEqual(blocked(dapiRequests: 1), "Wait for the 3DAPI request to finish.")
        XCTAssertEqual(blocked(quoteWrites: 1), "Wait for the 3DAPI request to finish.", "a quote write outlives its sheet")

        // A write waiting for a reply comes before everything else.
        XCTAssertEqual(blocked(dapiOrderSessionReason: "Wait for 3DAPI to answer the order or cancellation first.",
                               writes: [.payment], busy: true, modal: true, dapiRequests: 1, quoteSheets: 1, quoteWrites: 1),
                       "Wait for 3DAPI to answer the order or cancellation first.")
        XCTAssertEqual(blocked(writes: [.payment, .dapiOrder], busy: true),
                       "Wait for 3DAPI to answer the order or cancellation first.")
        XCTAssertEqual(blocked(writes: [.upload], busy: true, modal: true),
                       "Wait for Slant to answer the request that’s still waiting first.")
    }

    func testTheOrderSessionBlocksASwitch() {
        let session = DapiOrderSession()
        XCTAssertNil(blocked(dapiOrderSessionReason: session.changeBlockedReason))
        session.sheetOpened()
        XCTAssertEqual(blocked(dapiOrderSessionReason: session.changeBlockedReason), "Close the 3DAPI order sheet first.")
        session.sheetClosed()
        XCTAssertNil(blocked(dapiOrderSessionReason: session.changeBlockedReason))
    }

    func testOrderWatchRunsOnlyFor3DAPIWithAKey() {
        XCTAssertTrue(dapiOrderWatchShouldBeActive(service: .dapi, dapiKeySaved: true))
        XCTAssertFalse(dapiOrderWatchShouldBeActive(service: .dapi, dapiKeySaved: false))
        XCTAssertFalse(dapiOrderWatchShouldBeActive(service: .slant, dapiKeySaved: true))
        XCTAssertFalse(dapiOrderWatchShouldBeActive(service: .slant, dapiKeySaved: false))
    }

    // MARK: Main window

    func testConnectPromptIsSlantOnly() {
        // Slant: unchanged.
        XCTAssertTrue(showsConnectAccountPrompt(destination: .orders, hasKey: false, hasLocalModels: true, service: .slant))
        XCTAssertTrue(showsConnectAccountPrompt(destination: .models, hasKey: false, hasLocalModels: false, service: .slant))
        XCTAssertFalse(showsConnectAccountPrompt(destination: .models, hasKey: false, hasLocalModels: true, service: .slant))
        XCTAssertFalse(showsConnectAccountPrompt(destination: .orders, hasKey: true, hasLocalModels: false, service: .slant))
        // 3DAPI: never the Slant prompt, with or without a Slant key or library.
        for destination in Destination.allCases {
            for hasKey in [false, true] {
                for hasLocalModels in [false, true] {
                    XCTAssertFalse(showsConnectAccountPrompt(destination: destination, hasKey: hasKey, hasLocalModels: hasLocalModels,
                                                             service: .dapi), "\(destination)")
                }
            }
        }
    }

    func testSidebarBadgeFollowsTheService() {
        XCTAssertEqual(ordersSidebarBadgeCount(service: .slant, slantCount: 3, dapiCount: 5), 3)
        XCTAssertEqual(ordersSidebarBadgeCount(service: .dapi, slantCount: 3, dapiCount: 5), 5)
        XCTAssertEqual(ordersSidebarBadgeCount(service: .dapi, slantCount: 3, dapiCount: 0), 0, "never Slant's count with 3DAPI")
    }

    func testSlantRefreshAndMenusFollowTheService() {
        for destination in Destination.allCases {
            XCTAssertTrue(slantRefreshAvailable(service: .slant, destination: destination))
        }
        for destination in [Destination.models, .orders, .catalog, .materials, .components, .stationery] {
            XCTAssertFalse(slantRefreshAvailable(service: .dapi, destination: destination), "\(destination) shows 3DAPI")
        }
        XCTAssertTrue(slantRefreshAvailable(service: .dapi, destination: .api), "the Workbench is Slant's")
        XCTAssertTrue(slantRefreshAvailable(service: .dapi, destination: .activity))

        XCTAssertTrue(slantOrderMenuCommandsAvailable(service: .slant))
        XCTAssertFalse(slantOrderMenuCommandsAvailable(service: .dapi))
        XCTAssertEqual(newOrderMenuTitle(service: .slant), "New Order Draft…")
        XCTAssertEqual(newOrderMenuTitle(service: .dapi), "New 3DAPI Order…")
    }

    func testFooterNamesTheService() {
        XCTAssertEqual(slantConnectionFooterStatus("Connected to Slant 3D"), "Connected to Slant 3D")
        XCTAssertEqual(slantConnectionFooterStatus("Couldn’t reach Slant 3D"), "Couldn’t reach Slant 3D")
        XCTAssertEqual(slantConnectionFooterStatus("Not connected"), "Slant 3D · Not connected")
        XCTAssertEqual(slantConnectionFooterStatus("Connecting…"), "Slant 3D · Connecting…")

        let quoting = DapiAccount(kind: "integrator", approval: "pending", effectiveScopes: ["quotes:read", "quotes:write", "orders:read"])
        let ordering = DapiAccount(kind: "integrator", approval: "approved",
                                   effectiveScopes: ["quotes:read", "quotes:write", "orders:read", "orders:write"])
        XCTAssertEqual(dapiConnectionFooterStatus(keySaved: false, account: nil, onboarding: nil), "3DAPI · No key")
        XCTAssertEqual(dapiConnectionFooterStatus(keySaved: false, account: ordering, onboarding: nil), "3DAPI · No key")
        XCTAssertEqual(dapiConnectionFooterStatus(keySaved: true, account: nil, onboarding: nil), "3DAPI · Key saved")
        XCTAssertEqual(dapiConnectionFooterStatus(keySaved: true, account: quoting, onboarding: nil), "3DAPI · Quotes only")
        XCTAssertEqual(dapiConnectionFooterStatus(keySaved: true, account: ordering, onboarding: nil), "Connected to 3DAPI")
        XCTAssertTrue(dapiCanOrder(keySaved: true, account: ordering, onboarding: nil))
        let billing = DapiOnboarding(status: "approved", approvedFiles: 10, requiredFiles: 10, uploadsUsed: 0, uploadsLimit: nil,
                                     orderBlockers: ["billing_details_missing"])
        XCTAssertEqual(dapiConnectionFooterStatus(keySaved: true, account: ordering, onboarding: billing), "3DAPI · Quotes only")
        XCTAssertFalse(dapiCanOrder(keySaved: true, account: ordering, onboarding: billing))
        XCTAssertEqual(dapiConnectionFooterStatus(keySaved: true, account: DapiAccount(kind: "designer", approval: nil, effectiveScopes: []),
                                                  onboarding: nil), "3DAPI · Key can’t be used")
        XCTAssertFalse(dapiCanOrder(keySaved: false, account: ordering, onboarding: nil))
    }

    // MARK: Models' 3DAPI next steps

    func testDapiNextSteps() {
        func step(selection: Bool = true, local: Bool = true, file: Bool = true, key: Bool = true, quantity: Bool = true) -> DapiModelsNextStep {
            dapiModelsNextStep(hasSelection: selection, selectedIsLocal: local, localFileExists: file, keySaved: key, quantityValid: quantity)
        }
        XCTAssertEqual(step(selection: false, local: false, file: false, key: false, quantity: false), .needsModel)
        XCTAssertEqual(step(local: false, file: false, key: false), .needsLocalCopy, "an uploaded Slant model needs a local copy")
        XCTAssertEqual(step(file: false, key: false), .fileMissing)
        XCTAssertEqual(step(key: false, quantity: false), .needsKey, "3DAPI chosen without a key says to add one")
        XCTAssertEqual(step(quantity: false), .invalidQuantity)
        XCTAssertEqual(step(), .ready)

        XCTAssertEqual(dapiModelsNextStepStatus(.needsKey, orderingProblem: nil),
                       "Add your 3DAPI integrator key in Settings › Account to quote and order with 3DAPI.")
        XCTAssertTrue(dapiModelsNextStepStatus(.ready, orderingProblem: nil).contains("press Place Order"))
        XCTAssertEqual(dapiModelsNextStepStatus(.ready, orderingProblem: "Add your business billing details in 3DAPI’s dashboard before ordering."),
                       "Add your business billing details in 3DAPI’s dashboard before ordering.")
        XCTAssertEqual(dapiModelsNextStepStatus(.needsKey, orderingProblem: "anything"),
                       dapiModelsNextStepStatus(.needsKey, orderingProblem: nil), "the problem replaces only the ready line")
        for step in [DapiModelsNextStep.needsModel, .needsLocalCopy, .fileMissing, .needsKey, .invalidQuantity, .ready] {
            XCTAssertFalse(dapiModelsNextStepStatus(step, orderingProblem: nil).isEmpty)
        }
    }

    func testComposerPrefills() {
        let id = UUID()
        XCTAssertEqual(dapiOrderPrefill(modelID: id, quantity: 4), DapiComposerPrefill(modelID: id, quantity: 4, countryCode: nil))
        XCTAssertEqual(dapiOrderPrefill(modelID: id, quantity: 0).quantity, 1)
        XCTAssertEqual(dapiOrderPrefill(modelID: id, quantity: 20_000).quantity, 10_000)
        XCTAssertFalse(dapiOrderPrefill(modelID: id, quantity: 4).useSellerAddress)

        let sample = dapiSampleOrderPrefill(modelID: id)
        XCTAssertEqual(sample, DapiComposerPrefill(modelID: id, quantity: 1, countryCode: nil, useSellerAddress: true))
    }

    // MARK: 3DAPI's materials

    private func material(_ id: String, _ name: String, type: String?, color: String? = nil, hex: String? = nil) -> DapiMaterial {
        DapiMaterial(id: id, name: name, color: color, colorHex: hex, filamentType: type)
    }

    func testMaterialGroups() {
        let list = [
            material("mat_5", "Wood fill", type: nil),
            material("mat_4", "TPU Black", type: "tpu"),
            material("mat_3", "PETG White", type: "petg", color: "White"),
            material("mat_2", "PLA Red", type: "pla", color: "Red"),
            material("mat_1", "pla Black", type: "PLA", color: "Black"),
            material("mat_6", "ASA Grey", type: "asa"),
            material("mat_7", "Same", type: "pla"),
            material("mat_0", "Same", type: "pla"),
        ]
        let groups = dapiMaterialGroups(list)
        XCTAssertEqual(groups.map(\.title), ["PLA", "PETG", "ASA", "TPU", "Other"])
        XCTAssertEqual(groups[0].materials.map(\.id), ["mat_1", "mat_2", "mat_0", "mat_7"], "by name, then ID")
        XCTAssertEqual(dapiMaterialGroups(list.reversed()), groups, "never depends on 3DAPI's order")

        XCTAssertEqual(dapiMaterialGroups(list, search: "red").flatMap { $0.materials.map(\.id) }, ["mat_2"])
        XCTAssertEqual(dapiMaterialGroups(list, search: "white").map(\.title), ["PETG"], "colour matches too")
        XCTAssertEqual(dapiMaterialGroups(list, search: "petg").map(\.title), ["PETG"], "type matches too")
        XCTAssertTrue(dapiMaterialGroups(list, search: "nylon").isEmpty)
        XCTAssertEqual(dapiMaterialGroups(list, search: "  ").count, 5)
        XCTAssertTrue(dapiMaterialGroups([]).isEmpty)
    }

    func testColourSwatches() throws {
        let red = try XCTUnwrap(dapiColorComponents("#FF0000"))
        XCTAssertEqual(red.red, 1)
        XCTAssertEqual(red.green, 0)
        XCTAssertEqual(red.blue, 0)
        let grey = try XCTUnwrap(dapiColorComponents(" 80807f "))
        XCTAssertEqual(grey.red, 128.0 / 255, accuracy: 0.0001)
        XCTAssertEqual(grey.blue, 127.0 / 255, accuracy: 0.0001)
        for bad in [nil, "", "#FFF", "#GGGGGG", "#FF00001", "red", "#+12345"] as [String?] {
            XCTAssertNil(dapiColorComponents(bad), bad ?? "nil")
        }
    }
}
