import XCTest
@testable import Plinth

// Round 20: the app shell, Settings, notices and colours (contrast, one main window, menus, dialogs, wording).

final class ThemeContrastTests: XCTestCase {
    private let white = StudioRGB(255, 255, 255)

    func testTheContrastMathsMatchesWCAG() {
        XCTAssertEqual(wcagRelativeLuminance(StudioRGB(0, 0, 0)), 0, accuracy: 1e-9)
        XCTAssertEqual(wcagRelativeLuminance(white), 1, accuracy: 1e-9)
        XCTAssertEqual(wcagContrastRatio(StudioRGB(0, 0, 0), white), 21, accuracy: 1e-9)
        XCTAssertEqual(wcagContrastRatio(white, white), 1, accuracy: 1e-9)
        // Order doesn't matter, and #777777 on white is the classic 4.48:1.
        XCTAssertEqual(wcagContrastRatio(StudioRGB(119, 119, 119), white), wcagContrastRatio(white, StudioRGB(119, 119, 119)))
        XCTAssertEqual(wcagContrastRatio(StudioRGB(119, 119, 119), white), 4.48, accuracy: 0.01)
        // Composite: half of black over white is mid grey.
        XCTAssertEqual(wcagComposite(StudioRGB(0, 0, 0), opacity: 0.5, over: white), StudioRGB(127.5, 127.5, 127.5))
    }

    /// Warning, success and error text reaches 4.5:1 on every light and dark background, and badge text on its own
    /// 14% tint (on white and on the dark window) does too.
    func testStatusColoursReachTextContrastInBothAppearances() {
        let pairs: [(String, StudioRGB, StudioRGB)] = [
            ("warning", StudioPalette.warningLight, StudioPalette.warningDark),
            ("success", StudioPalette.successLight, StudioPalette.successDark),
            ("error", StudioPalette.errorLight, StudioPalette.errorDark)
        ]
        for (name, light, dark) in pairs {
            for background in StudioPalette.lightBackgrounds {
                XCTAssertGreaterThanOrEqual(wcagContrastRatio(light, background), 4.5, "\(name) light on \(background)")
            }
            for background in StudioPalette.darkBackgrounds {
                XCTAssertGreaterThanOrEqual(wcagContrastRatio(dark, background), 4.5, "\(name) dark on \(background)")
            }
            let lightBadge = wcagComposite(light, opacity: StudioPalette.badgeTintOpacity, over: white)
            XCTAssertGreaterThanOrEqual(wcagContrastRatio(light, lightBadge), 4.5, "\(name) badge on white")
            let darkBadge = wcagComposite(dark, opacity: StudioPalette.badgeTintOpacity, over: StudioPalette.darkBackgrounds[0])
            XCTAssertGreaterThanOrEqual(wcagContrastRatio(dark, darkBadge), 4.5, "\(name) badge on the dark window")
            // Primary text stays readable on the warning notice strip's tint.
            let lightStrip = wcagComposite(light, opacity: StudioPalette.noticeTintOpacity, over: StudioPalette.lightBackgrounds[1])
            XCTAssertGreaterThanOrEqual(wcagContrastRatio(StudioRGB(0, 0, 0), lightStrip), 4.5)
            XCTAssertGreaterThanOrEqual(wcagContrastRatio(light, lightStrip), 4.5, "\(name) icon/text on its strip")
            let darkStrip = wcagComposite(dark, opacity: StudioPalette.noticeTintOpacity, over: StudioPalette.darkBackgrounds[0])
            XCTAssertGreaterThanOrEqual(wcagContrastRatio(white, darkStrip), 4.5)
            XCTAssertGreaterThanOrEqual(wcagContrastRatio(dark, darkStrip), 4.5, "\(name) dark icon/text on its strip")
        }
    }

    /// Filled (prominent) buttons put white text on the accent; the accent is also text and icons on the window.
    func testTheAccentKeepsContrastForFilledButtonsAndText() {
        XCTAssertGreaterThanOrEqual(wcagContrastRatio(white, StudioPalette.accentLight), 4.5, "white on the light accent")
        XCTAssertGreaterThanOrEqual(wcagContrastRatio(StudioPalette.accentLight, white), 4.5, "light accent text on white")
        XCTAssertGreaterThanOrEqual(wcagContrastRatio(StudioPalette.accentLight, StudioPalette.lightBackgrounds[1]), 3,
                                    "light accent icons on the window grey")
        XCTAssertGreaterThanOrEqual(wcagContrastRatio(white, StudioPalette.accentDark), 3.5, "white on the dark accent")
        XCTAssertGreaterThanOrEqual(wcagContrastRatio(StudioPalette.accentDark, StudioPalette.darkBackgrounds[0]), 4.5,
                                    "dark accent text on the dark window")
        for background in StudioPalette.darkBackgrounds {
            XCTAssertGreaterThanOrEqual(wcagContrastRatio(StudioPalette.accentDark, background), 3, "dark accent icons on \(background)")
        }
    }

    func testStatusColoursStillReadAsTheirHue() {
        func hue(_ c: StudioRGB) -> Double {
            let r = c.red / 255, g = c.green / 255, b = c.blue / 255
            let maxC = max(r, g, b), minC = min(r, g, b), d = maxC - minC
            guard d > 0 else { return 0 }
            var h: Double
            if maxC == r { h = (g - b) / d } else if maxC == g { h = (b - r) / d + 2 } else { h = (r - g) / d + 4 }
            h *= 60
            return h < 0 ? h + 360 : h
        }
        for c in [StudioPalette.warningLight, StudioPalette.warningDark, StudioPalette.accentLight, StudioPalette.accentDark] {
            XCTAssertTrue((15...45).contains(hue(c)), "orange/amber: \(c)")
        }
        for c in [StudioPalette.successLight, StudioPalette.successDark] { XCTAssertTrue((100...160).contains(hue(c)), "green: \(c)") }
        for c in [StudioPalette.errorLight, StudioPalette.errorDark] {
            XCTAssertTrue(hue(c) < 12 || hue(c) > 345, "red: \(c)")
        }
    }
}

extension ShellUXTests {
    // MARK: One main window

    func testAnOpenMainWindowTakesEveryExternalEvent() throws {
        XCTAssertEqual(mainWindowExternalEvents, ["*"])
        let source = try String(contentsOf: shellSourceURL("PlinthApp.swift"), encoding: .utf8)
        XCTAssertTrue(source.contains(".handlesExternalEvents(preferring: mainWindowExternalEvents, allowing: mainWindowExternalEvents)"),
                      "The main window's content must claim external events, or SwiftUI opens a second window for a Finder open")
        XCTAssertEqual(source.components(separatedBy: "WindowGroup(").count - 1, 1, "One main window scene")
    }

    func testAFinderOpenWaitsForTheWindowSwiftUIOpensAfterItWasClosed() {
        XCTAssertEqual(externalOpenRevealDelay(mainWindowOpen: true), 0)
        XCTAssertGreaterThan(externalOpenRevealDelay(mainWindowOpen: false), 0)
        // Within the reveal's own two-second guard and well before a waiting menu command is dropped (5 s).
        XCTAssertLessThan(externalOpenRevealDelay(mainWindowOpen: false), 2)
    }

    // MARK: File menu order tools (Slant)

    func testSlantOrderToolsFollowOneRule() {
        for destination in [Destination.models, .orders, .catalog, .api, .activity] {
            for tool in [DapiOrderToolRequest.trackingForYourShop, .spendingReport] {
                XCTAssertTrue(slantOrderToolMenuEnabled(tool, destination: destination, ordersLoaded: true, modalUIShown: false),
                              "\(tool) works on every loaded order, from \(destination)")
                XCTAssertFalse(slantOrderToolMenuEnabled(tool, destination: destination, ordersLoaded: false, modalUIShown: false))
                XCTAssertFalse(slantOrderToolMenuEnabled(tool, destination: destination, ordersLoaded: true, modalUIShown: true))
            }
            // Export saves the rows the Orders list shows, so it needs Orders on screen (as `ordersExportMenuEnabled`).
            XCTAssertEqual(slantOrderToolMenuEnabled(.exportOrders, destination: destination, ordersLoaded: true, modalUIShown: false),
                           ordersExportMenuEnabled(destination: destination, ordersLoaded: true, sheetPresented: false))
            XCTAssertFalse(slantOrderToolMenuEnabled(.exportOrders, destination: destination, ordersLoaded: true, modalUIShown: true))
            XCTAssertFalse(slantOrderToolMenuEnabled(.reload, destination: destination, ordersLoaded: true, modalUIShown: false))
        }
    }

    // MARK: Catalogue

    func testCatalogueIsTheNameShownButTheSavedValueStays() {
        XCTAssertEqual(Destination.catalog.title, "Catalogue")
        XCTAssertEqual(Destination.catalog.rawValue, "Catalog", "Saved as lastSidebarDestination; must not change")
        XCTAssertEqual(restoredSidebarDestination(saved: "Catalog", showDeveloperTools: false), .catalog)
        for destination in Destination.allCases where destination != .catalog {
            XCTAssertEqual(destination.title, destination.rawValue)
        }
        XCTAssertTrue(studioHelpSections.contains { $0.title == "Catalogue" })
        for section in studioHelpSections {
            XCTAssertNil(section.body.range(of: #"\bCatalog\b"#, options: .regularExpression), "British spelling: \(section.title)")
        }
        XCTAssertFalse(printServiceSettingsFooter.contains("Catalog’"))
    }

    func testHelpDescribesTheShowMenuAndLoadRecentOrders() {
        let models = studioHelpSections.first { $0.title == "Models" }?.body ?? ""
        XCTAssertTrue(models.contains("The **Show** menu above the model list"))
        XCTAssertTrue(models.contains("uploaded models or those ready to upload"))
        let orders = studioHelpSections.first { $0.title == "Orders" }?.body ?? ""
        XCTAssertTrue(orders.contains("**Load Recent Orders**"))
    }

    // MARK: Notices and dialogs

    func testNoticeButtonsNameTheirNoticeAfterTheVisibleWord() {
        let labels = [studioNoticeButtonAccessibilityLabel("Dismiss", notice: orderWatchNoticeAccessibilityName),
                      studioNoticeButtonAccessibilityLabel("Dismiss", notice: savedProductStockNoticeAccessibilityName),
                      studioNoticeButtonAccessibilityLabel("Dismiss", notice: slantAPINoticeAccessibilityName)]
        XCTAssertEqual(labels, ["Dismiss Order Updates Notice", "Dismiss Materials Notice", "Dismiss Slant API Notice"])
        XCTAssertEqual(Set(labels).count, labels.count, "Each notice's Dismiss is told apart")
        XCTAssertEqual(studioNoticeButtonAccessibilityLabel("Show", notice: orderWatchNoticeAccessibilityName), "Show Order Updates Notice")
        XCTAssertEqual(StudioNoticeKind.warning.symbol, "exclamationmark.triangle.fill")
        XCTAssertEqual(StudioNoticeKind.information.symbol, "info.circle.fill")
    }

    /// In every destructive confirmation dialog of the shell and Settings files, the safe (cancel) button is the Return
    /// default and the destructive one never is; the key dialogs say "Remove Key".
    func testDestructiveConfirmationsDefaultToTheSafeButton() throws {
        let files = ["SettingsView.swift", "AnthropicSettingsView.swift", "DapiSettingsView.swift", "ImageTo3DSettingsView.swift",
                     "ShopifySettingsView.swift", "OrderWatchView.swift"]
        var checked = 0
        for file in files {
            let source = try String(contentsOf: shellSourceURL(file), encoding: .utf8)
            for block in source.components(separatedBy: ".confirmationDialog(").dropFirst() {
                let dialog = block.components(separatedBy: "} message:").first ?? block
                guard dialog.contains("role: .destructive") else { continue }
                checked += 1
                XCTAssertTrue(dialog.contains("titleVisibility: .visible"), file)
                let lines = dialog.components(separatedBy: "\n")
                guard let shortcut = lines.firstIndex(where: { $0.contains(".keyboardShortcut(.defaultAction)") }) else {
                    XCTFail("\(file): a destructive dialog without a safe default"); continue
                }
                // The shortcut belongs to the cancel button just above it, never to the destructive one.
                let owner = lines[..<shortcut].last { $0.contains("Button(") } ?? ""
                XCTAssertTrue(owner.contains("role: .cancel"), "\(file): \(owner)")
                XCTAssertFalse(owner.contains("role: .destructive"), file)
                if dialog.contains("key?\"") { XCTAssertTrue(dialog.contains("Button(\"Remove Key\", role: .destructive)"), file) }
            }
        }
        XCTAssertEqual(checked, 6, "Disconnect (Slant, Shopify), Remove Key (Claude, 3DAPI, Meshy/Tripo) and Forget Statuses")
    }

    func testShellWording() throws {
        let studio = try String(contentsOf: shellSourceURL("StudioView.swift"), encoding: .utf8)
        XCTAssertTrue(studio.contains(".alert(\"Couldn’t complete the request\""))
        XCTAssertFalse(studio.contains("Unable to"))
        XCTAssertTrue(studio.contains("\"No activity yet\""))
        XCTAssertTrue(studio.contains("ContentUnavailableView.search(text:"))
        let workbench = try String(contentsOf: shellSourceURL("APIWorkbenchView.swift"), encoding: .utf8)
        XCTAssertTrue(workbench.contains("title: \"Choose an operation\""))
        let api = try String(contentsOf: shellSourceURL("SlantAPIChangesView.swift"), encoding: .utf8)
        XCTAssertFalse(api.contains("Button(\"Details…\")"), "Details only opens Settings: no ellipsis")
        let service = try String(contentsOf: shellSourceURL("PrintService.swift"), encoding: .utf8)
        XCTAssertFalse(service.contains("Picker(\"Print service\""), "The row label doesn't repeat the section heading")
        XCTAssertTrue(dapiModelsNextStepStatus(.needsKey, orderingProblem: nil).hasPrefix("Add a 3DAPI key"))
    }

    private func shellSourceURL(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Plinth").appendingPathComponent(name)
    }
}
