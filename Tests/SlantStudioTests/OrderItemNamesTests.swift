import XCTest
@testable import SlantStudio

/// Order item names, the review sheet's item-list layout choice and the import sheet's row/button copy.
final class OrderItemNamesTests: XCTestCase {
    /// The shape GET /orders/{id} returns for a composer-created print item: every name is null.
    private let composerItem: [String: Any] = [
        "currency": "USD", "filamentId": "fil-1", "name": NSNull(), "price": "9.93",
        "printItem": ["filamentId": "fil-1", "name": NSNull(), "publicFileServiceId": "file-1", "SKU": NSNull()],
        "publicFileServiceId": "file-1", "quantity": 1, "SKU": NSNull(), "status": "PROCESSING", "type": "PRINT"
    ]

    func testFileIDFromTopLevelOrPrintItem() {
        XCTAssertEqual(orderItemFileID(composerItem), "file-1")
        XCTAssertEqual(orderItemFileID(["printItem": ["publicFileServiceId": " file-2 "]]), "file-2")
        XCTAssertEqual(orderItemFileID(["publicFileServiceId": "", "printItem": ["publicFileServiceId": "file-3"]]), "file-3")
        XCTAssertNil(orderItemFileID(["publicFileServiceId": NSNull()]))
        XCTAssertNil(orderItemFileID(["type": "COMPONENT"]))
    }

    func testModelNamesPreferLibraryNameThenCloudName() {
        let models = [
            LocalModel(name: "Desk Tidy", filePath: "/tmp/a.stl", remoteID: "file-1"),
            LocalModel(name: "Second copy", filePath: "/tmp/b.stl", remoteID: "file-1"),
            LocalModel(name: "   ", filePath: "/tmp/c.stl", remoteID: "file-2"),
            LocalModel(name: "Not uploaded", filePath: "/tmp/d.stl")
        ]
        let files = [
            Record(values: ["publicFileServiceId": "file-1", "name": "tidy_v3.stl"]),
            Record(values: ["publicFileServiceId": "file-2", "name": "bracket.stl"]),
            Record(values: ["publicFileServiceId": "file-3", "name": NSNull()]),
            Record(values: ["publicFileServiceId": "file-4", "name": "  "])
        ]
        let names = orderItemModelNames(localModels: models, files: files)
        XCTAssertEqual(names["file-1"], "Desk Tidy", "the first library model linked to the file wins")
        XCTAssertEqual(names["file-2"], "bracket.stl", "a blank library name falls through to the uploaded name")
        XCTAssertNil(names["file-3"])
        XCTAssertNil(names["file-4"])
        XCTAssertEqual(names.count, 2)
    }

    func testComposerItemShowsModelNameOrThreeDPrint() {
        let names = ["file-1": "Desk Tidy"]
        XCTAssertEqual(orderItemDisplayName(composerItem, modelNames: names), "Desk Tidy")
        XCTAssertEqual(orderItemLineText(composerItem, modelNames: names), "1 × Desk Tidy")
        // Unknown file (deleted, or files not loaded): the type, not "Print".
        XCTAssertEqual(orderItemDisplayName(composerItem), "3D print")
        XCTAssertEqual(orderItemLineText(composerItem, modelNames: ["other": "X"]), "1 × 3D print")
        // An item's own name still wins over the library.
        var named = composerItem
        named["name"] = "Custom listing name"
        XCTAssertEqual(orderItemDisplayName(named, modelNames: names), "Custom listing name")
        // A component's own name wins even if a file ID were present.
        XCTAssertEqual(orderItemDisplayName(["componentName": "Hinge", "publicFileServiceId": "file-1"], modelNames: names), "Hinge")
        XCTAssertEqual(orderItemDisplayName([:]), "Item")
        XCTAssertEqual(orderItemDisplayName(["type": "SOME_THING"]), "Some Thing")
    }

    func testLineTextQuantities() {
        XCTAssertEqual(orderItemLineText(["quantity": 3, "name": "A"]), "3 × A")
        XCTAssertEqual(orderItemLineText(["quantity": "12", "name": "A"]), "12 × A")
        XCTAssertEqual(orderItemLineText(["name": "A"]), "1 × A")
        XCTAssertEqual(orderItemLineText(["quantity": NSNull(), "name": "A"]), "1 × A")
        XCTAssertEqual(orderItemLineText(["quantity": 2.5, "name": "A"]), "2.5 × A")
    }

    func testMaterialNameForComposerItem() {
        let filaments = [Record(values: ["id": "fil-1", "name": "PLA Black"])]
        XCTAssertEqual(orderItemMaterialName(composerItem, filaments: filaments), "PLA Black")
        XCTAssertNil(orderItemMaterialName(composerItem, filaments: []))
    }

    func testReviewItemListScrollsOnlyWhenLong() {
        XCTAssertFalse(orderReviewItemListScrolls(itemCount: 0))
        XCTAssertFalse(orderReviewItemListScrolls(itemCount: 1))
        XCTAssertFalse(orderReviewItemListScrolls(itemCount: orderReviewPlainItemLimit))
        XCTAssertTrue(orderReviewItemListScrolls(itemCount: orderReviewPlainItemLimit + 1))
        XCTAssertTrue(orderReviewItemListScrolls(itemCount: 200))
    }

    func testImportCreateButtonTitle() {
        XCTAssertEqual(orderImportCreateButtonTitle(0), "Create Drafts")
        XCTAssertEqual(orderImportCreateButtonTitle(-1), "Create Drafts")
        XCTAssertEqual(orderImportCreateButtonTitle(1), "Create 1 Draft")
        XCTAssertEqual(orderImportCreateButtonTitle(7), "Create 7 Drafts")
    }

    func testImportVisibleWarningsKeepOtherWarnings() {
        let other = "The shipping company “Acme” isn’t sent: Slant drafts have no company field."
        let warnings = [other, orderImportAlreadyImportedWarning("ORD-1")]
        XCTAssertEqual(orderImportVisibleWarnings(warnings, rowState: .created("ORD-1")), [other])
        XCTAssertEqual(orderImportVisibleWarnings(warnings, rowState: .refused("No")), warnings)
        XCTAssertEqual(orderImportVisibleWarnings([], rowState: .created("ORD-1")), [])
    }
}
