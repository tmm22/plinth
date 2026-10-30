import XCTest
@testable import Plinth

final class LibraryRemovalAndCatalogIconTests: XCTestCase {
    private let support = URL(fileURLWithPath: "/tmp/PlinthTests/Support", isDirectory: true)

    func testManagedCopyOnlyMatchesFilesInsideTheAppModelsFolder() {
        XCTAssertTrue(isManagedModelCopy(support.appendingPathComponent("Models/abc.stl"), supportDirectory: support))
        XCTAssertFalse(isManagedModelCopy(URL(fileURLWithPath: "/Users/me/Desktop/part.stl"), supportDirectory: support))
        XCTAssertFalse(isManagedModelCopy(support.appendingPathComponent("ModelsBackup/abc.stl"), supportDirectory: support))
        XCTAssertFalse(isManagedModelCopy(support.appendingPathComponent("Models/../models.json"), supportDirectory: support))
        XCTAssertFalse(isManagedModelCopy(support.appendingPathComponent("Models"), supportDirectory: support))
    }

    func testRemovalCopyReassuresOriginalsAreKept() {
        let local = localModelRemovalMessage(name: "Bracket", isUploaded: false)
        XCTAssertTrue(local.contains("Bracket"))
        XCTAssertTrue(local.contains("original file on your Mac isn’t touched"))
        XCTAssertFalse(local.contains("Slant account"))
        XCTAssertTrue(localModelRemovalMessage(name: "Bracket", isUploaded: true).contains("stays in your Slant account"))

        let cloud = cloudModelDeletionMessage(name: "Bracket")
        XCTAssertTrue(cloud.contains("permanently deleted"))
        XCTAssertTrue(cloud.contains("can’t be undone"))
    }

    func testComponentSymbolsComeFromNameCategoryAndTags() {
        func symbol(_ values: [String: Any], category: String? = nil, kind: Destination = .components) -> String {
            catalogItemSymbol(Record(values: values), kind: kind, categoryName: category)
        }
        XCTAssertEqual(symbol(["name": "Neodymium Magnets 6x3mm"]), "circle.circle")
        XCTAssertEqual(symbol(["name": "CR2032 Battery"]), "battery.100")
        XCTAssertEqual(symbol(["name": "Adhesive Feet (4 pack)"]), "circle.bottomhalf.filled")
        XCTAssertEqual(symbol(["name": "Heat Set Insert"]), "wrench.and.screwdriver")
        XCTAssertEqual(symbol(["name": "Hex part", "tags": ["m3", "bracket"]]), "wrench.and.screwdriver")
        XCTAssertEqual(symbol(["name": "Key Ring"]), "key")
        XCTAssertEqual(symbol(["name": "Warm White LEDs"]), "lightbulb")
        XCTAssertEqual(symbol(["name": "Widget"], category: "Electronics › Switches"), "switch.2")
        XCTAssertEqual(symbol(["name": "Lightweight widget"]), Destination.components.icon)
        XCTAssertEqual(symbol(["name": "Thank You Insert"], kind: .stationery), "text.rectangle")
        XCTAssertEqual(symbol(["name": "Mystery"], kind: .stationery), Destination.stationery.icon)
    }

    func testCatalogImageURLAcceptsDocumentedKeysOverHTTPSOnly() {
        XCTAssertEqual(
            catalogItemImageURL(Record(values: ["imageUrl": "https://cdn.example/a.png"]))?.absoluteString,
            "https://cdn.example/a.png"
        )
        XCTAssertEqual(
            catalogItemImageURL(Record(values: ["image_url": "https://cdn.example/b.png"]))?.absoluteString,
            "https://cdn.example/b.png"
        )
        XCTAssertNil(catalogItemImageURL(Record(values: ["imageUrl": "http://cdn.example/a.png"])))
        XCTAssertNil(catalogItemImageURL(Record(values: [:])))
    }

    func testHiddenCloudModelsAreFilteredUnlessShown() {
        let files = [
            Record(values: ["publicFileServiceId": "a", "name": "Bracket"]),
            Record(values: ["publicFileServiceId": "b", "name": "Hook"])
        ]
        XCTAssertEqual(visibleCloudFiles(files, hidden: ["a"], showHidden: false).map(\.id), ["b"])
        XCTAssertEqual(visibleCloudFiles(files, hidden: ["a"], showHidden: true).map(\.id), ["a", "b"])
        XCTAssertEqual(visibleCloudFiles(files, hidden: [], showHidden: false).count, 2)
    }

    func testDeleteRefusalExplainsAndOffersHiding() {
        let withReason = cloudDeleteRefusalMessage(CloudDeleteRefusal(fileID: "a", name: "Bracket", slantReason: "Admin access required"))
        XCTAssertTrue(withReason.contains("admin access"))
        XCTAssertTrue(withReason.contains("“Admin access required”"))
        XCTAssertTrue(withReason.contains("hide “Bracket”"))
        let withoutReason = cloudDeleteRefusalMessage(CloudDeleteRefusal(fileID: "a", name: "Bracket", slantReason: nil))
        XCTAssertFalse(withoutReason.contains("Slant said"))
    }

    func testForbiddenErrorSurfacesSlantsReason() {
        XCTAssertEqual(
            APIError.http(status: 403, body: #"{"message":"Admin access required"}"#, retryAfter: nil, rateLimitReset: nil).userMessage,
            "Slant refused this request. Admin access required"
        )
    }

    func testUploadSizeLimitMatchesSlantDocs() {
        XCTAssertNil(uploadSizeProblem(fileBytes: 250_000_000))
        XCTAssertNil(uploadSizeProblem(fileBytes: 1_024))
        let problem = uploadSizeProblem(fileBytes: 250_000_001)
        XCTAssertNotNil(problem)
        XCTAssertTrue(problem?.contains("251 MB") == true)
        XCTAssertTrue(problem?.contains("250 MB") == true)
    }

    func testBuildVolumeWarningAndFootprintLabel() {
        XCTAssertFalse(exceedsSlantBuildVolume((220, 220, 220)))
        XCTAssertTrue(exceedsSlantBuildVolume((100, 221, 50)))
        XCTAssertEqual(footprintLabel((20, 15.25, 8)), "20.0 × 15.2 × 8.0 mm")
    }

    func testSidebarListsEveryTopLevelDestinationOnce() {
        let shown = sidebarDestinations(showDeveloperTools: true)
        XCTAssertEqual(Set(shown).count, shown.count)
        XCTAssertEqual(Set(shown), [.models, .orders, .catalog, .api, .activity])
        // Developer tools off (the default): only the three everyday destinations.
        XCTAssertEqual(sidebarDestinations(showDeveloperTools: false), [.models, .orders, .catalog])
        // Every listed destination, and every Catalog kind, has a distinct icon.
        let icons = (shown + Destination.catalogKinds).map(\.icon)
        XCTAssertEqual(Set(icons).count, icons.count)
    }
}

final class FilamentTypeTests: XCTestCase {
    private let filaments = [
        Record(values: ["publicId": "1", "name": "PLA Black", "profile": "PLA"]),
        Record(values: ["publicId": "2", "name": "PETG Clear", "profile": "PETG"]),
        Record(values: ["publicId": "3", "name": "PLA White", "profile": "pla "]),
        Record(values: ["publicId": "4", "name": "Mystery", "profile": ""]),
        Record(values: ["publicId": "5", "name": "New Resin", "profile": "ASA"])
    ]

    func testTypesComeFromLiveDataIncludingNewOnes() {
        XCTAssertEqual(filamentTypes(in: filaments), ["ASA", "PETG", "PLA", "Other"])
        XCTAssertEqual(filamentTypes(in: []), [])
    }

    func testFilteringByTypeNormalisesCaseAndWhitespace() {
        XCTAssertEqual(filamentsMatching(filaments, type: "PLA").map(\.id), ["1", "3"])
        XCTAssertEqual(filamentsMatching(filaments, type: otherFilamentType).map(\.id), ["4"])
        XCTAssertEqual(filamentsMatching(filaments, type: nil).count, filaments.count)
    }

    func testChangingTypeSwitchesToAnInStockMaterialOfThatType() {
        let list = [
            Record(values: ["publicId": "pla", "name": "PLA Black", "profile": "PLA"]),
            Record(values: ["publicId": "opm-out", "name": "OPM Grey", "profile": "OPM", "available": false]),
            Record(values: ["publicId": "opm", "name": "OPM Black", "profile": "OPM"])
        ]
        XCTAssertEqual(filamentIDAfterTypeChange(currentID: "pla", type: "OPM", filaments: list), "opm")
        XCTAssertEqual(filamentIDAfterTypeChange(currentID: "opm-out", type: "OPM", filaments: list), "opm-out")
        XCTAssertEqual(filamentIDAfterTypeChange(currentID: "pla", type: nil, filaments: list), "pla")
        XCTAssertEqual(filamentIDAfterTypeChange(currentID: "pla", type: "PETG", filaments: list), "pla")
    }
}
