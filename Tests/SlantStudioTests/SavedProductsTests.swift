import XCTest
@testable import SlantStudio

final class SavedProductsTests: XCTestCase {
    // MARK: Fixtures

    let pla = Record(values: ["id": "pla-black", "name": "PLA Black", "profile": "PLA", "available": true])
    let petgOut = Record(values: ["id": "petg-red", "name": "PETG Red", "profile": "PETG", "available": false])
    let box = Record(values: ["id": "box-1", "name": "Small box"])
    let slip = Record(values: ["id": "slip-1", "name": "Packing slip"])

    func model(_ name: String = "Bracket", remoteID: String? = "file-new") -> LocalModel {
        LocalModel(name: name, filePath: "/tmp/\(name).stl", remoteID: remoteID)
    }

    func printLine(model: LocalModel?, reference: String = "", filament: String = "pla-black", quantity: Int = 1) -> SavedProductLine {
        SavedProductLine(type: "PRINT", reference: reference, localModelID: model?.id, filamentID: filament, quantity: quantity)
    }

    func resolve(_ product: SavedProduct, units: Int = 1, models: [LocalModel] = [], filaments: [Record]? = nil,
                 components: [Record] = [], stationery: [Record] = []) -> SavedProductResolution {
        savedProductOrderLines(product, units: units, localModels: models, filaments: filaments ?? [pla, petgOut],
                               components: components, stationery: stationery)
    }

    // MARK: Resolver

    func testPerUnitQuantitiesMultiplyAndPerOrderLinesDont() throws {
        let bracket = model()
        let product = SavedProduct(name: "Shelf kit", sku: " KIT-1 ", lines: [
            printLine(model: bracket, reference: "file-new", quantity: 2),
            SavedProductLine(type: "COMPONENT", reference: "box-1", quantity: 1),
            SavedProductLine(type: "STATIONERY", reference: "slip-1", quantity: 1, perOrder: true)
        ])
        let result = resolve(product, units: 3, models: [bracket], components: [box], stationery: [slip])
        XCTAssertEqual(result.blockers, [])
        XCTAssertEqual(result.notes, [])
        XCTAssertEqual(result.lines.map(\.quantity), [6, 3, 1])
        XCTAssertEqual(result.lines.map(\.reference), ["file-new", "box-1", "slip-1"])
        XCTAssertEqual(result.lines.map(\.type), ["PRINT", "COMPONENT", "STATIONERY"])
        XCTAssertEqual(result.lines[0].filamentID, "pla-black")
        XCTAssertTrue(result.lines.allSatisfy { $0.sku == "KIT-1" })
        // The resolved lines are valid order items, with the SKU sent for each.
        let payloads = try result.lines.map { try $0.payload() }
        XCTAssertEqual(payloads[0]["publicFileServiceId"] as? String, "file-new")
        XCTAssertEqual(payloads[0]["quantity"] as? Int, 6)
        XCTAssertEqual(payloads[1]["componentId"] as? String, "box-1")
        XCTAssertEqual(payloads[2]["stationeryId"] as? String, "slip-1")
        XCTAssertEqual(payloads[2]["SKU"] as? String, "KIT-1")
    }

    func testQuantityCapAndOverflowBlock() {
        let bracket = model()
        let atCap = resolve(SavedProduct(name: "P", lines: [printLine(model: bracket, quantity: 5_000)]), units: 2, models: [bracket])
        XCTAssertEqual(atCap.blockers, [])
        XCTAssertEqual(atCap.lines.first?.quantity, 10_000)

        let overCap = resolve(SavedProduct(name: "P", lines: [printLine(model: bracket, quantity: 5_000)]), units: 3, models: [bracket])
        XCTAssertEqual(overCap.blockers.count, 1)
        XCTAssertTrue(overCap.blockers[0].contains("10,000"))

        let overflow = resolve(SavedProduct(name: "P", lines: [printLine(model: bracket, quantity: Int.max)]), units: 2, models: [bracket])
        XCTAssertTrue(overflow.blockers.contains { $0.contains("10,000") })

        let perOrderOverCap = resolve(SavedProduct(name: "P", lines: [
            SavedProductLine(type: "STATIONERY", reference: "slip-1", quantity: 20_000, perOrder: true)
        ]))
        XCTAssertTrue(perOrderOverCap.blockers.contains { $0.contains("10,000") })
    }

    func testInvalidUnitsQuantitiesAndEmptyProductsBlock() {
        let bracket = model()
        let product = SavedProduct(name: "P", lines: [printLine(model: bracket)])
        XCTAssertFalse(resolve(product, units: 0, models: [bracket]).blockers.isEmpty)
        XCTAssertFalse(resolve(product, units: -2, models: [bracket]).blockers.isEmpty)
        XCTAssertFalse(resolve(SavedProduct(name: "Empty"), models: [bracket]).blockers.isEmpty)
        let zero = resolve(SavedProduct(name: "P", lines: [printLine(model: bracket, quantity: 0)]), models: [bracket])
        XCTAssertEqual(zero.blockers.count, 1)
        XCTAssertFalse(zero.blockers[0].contains("10,000"))
    }

    func testReuploadedModelUsesLatestUploadWithNote() {
        let bracket = model(remoteID: "file-new")
        let result = resolve(SavedProduct(name: "P", lines: [printLine(model: bracket, reference: "file-old")]), models: [bracket])
        XCTAssertEqual(result.blockers, [])
        XCTAssertEqual(result.lines.first?.reference, "file-new")
        XCTAssertEqual(result.notes, ["Using the latest upload of “Bracket”."])
        // No note when the snapshot was simply empty (saved before upload).
        let firstUpload = resolve(SavedProduct(name: "P", lines: [printLine(model: bracket)]), models: [bracket])
        XCTAssertEqual(firstUpload.notes, [])
        XCTAssertEqual(firstUpload.lines.first?.reference, "file-new")
    }

    func testModelNotUploadedBlocksOnce() {
        for remoteID in [nil, "", "  "] as [String?] {
            let local = model(remoteID: remoteID)
            let result = resolve(SavedProduct(name: "P", lines: [printLine(model: local)]), models: [local])
            XCTAssertEqual(result.blockers.count, 1, "remoteID \(String(describing: remoteID))")
            XCTAssertTrue(result.blockers[0].contains("isn’t uploaded"))
        }
    }

    func testMissingModelUsesSnapshotOrBlocks() {
        let gone = model()
        let withSnapshot = resolve(SavedProduct(name: "P", lines: [printLine(model: gone, reference: "file-old")]), models: [])
        XCTAssertEqual(withSnapshot.blockers, [])
        XCTAssertEqual(withSnapshot.lines.first?.reference, "file-old")
        XCTAssertEqual(withSnapshot.notes.count, 1)
        XCTAssertTrue(withSnapshot.notes[0].contains("no longer in your library"))

        let noSnapshot = resolve(SavedProduct(name: "P", lines: [printLine(model: gone)]), models: [])
        XCTAssertEqual(noSnapshot.blockers.count, 1)
        XCTAssertTrue(noSnapshot.blockers[0].contains("no longer in your library"))

        let neverChosen = resolve(SavedProduct(name: "P", lines: [printLine(model: nil)]))
        XCTAssertEqual(neverChosen.blockers.count, 1)
        XCTAssertTrue(neverChosen.blockers[0].hasPrefix("Choose a model"))

        let referenceOnly = resolve(SavedProduct(name: "P", lines: [printLine(model: nil, reference: "file-x")]))
        XCTAssertEqual(referenceOnly.blockers, [])
        XCTAssertEqual(referenceOnly.lines.first?.reference, "file-x")
    }

    func testMaterialChecks() {
        let bracket = model()
        func blockers(_ filament: String, _ filaments: [Record]) -> [String] {
            resolve(SavedProduct(name: "P", lines: [printLine(model: bracket, filament: filament)]), models: [bracket], filaments: filaments).blockers
        }
        XCTAssertEqual(blockers("pla-black", [pla, petgOut]), [])
        XCTAssertEqual(blockers(" pla-black ", [pla, petgOut]), [], "stored IDs are trimmed before lookup")
        XCTAssertEqual(blockers("petg-red", [pla, petgOut]), ["PETG Red is out of stock."])
        XCTAssertEqual(blockers("gone", [pla, petgOut]).count, 1)
        XCTAssertTrue(blockers("gone", [pla, petgOut])[0].contains("no longer offered"))
        XCTAssertEqual(blockers("", [pla]).count, 1)
        // An unloaded material list never produces a false blocker.
        XCTAssertEqual(blockers("gone", []), [])
        XCTAssertEqual(blockers("petg-red", []), [])
    }

    func testComponentAndStationeryChecksSkipUnloadedCatalogs() {
        let product = SavedProduct(name: "P", lines: [
            SavedProductLine(type: "COMPONENT", reference: "box-9"),
            SavedProductLine(type: "STATIONERY", reference: "slip-9", perOrder: true)
        ])
        XCTAssertEqual(resolve(product).blockers, [], "unloaded catalogs are not checked")
        let loaded = resolve(product, components: [box], stationery: [slip]).blockers
        XCTAssertEqual(loaded.count, 2)
        XCTAssertTrue(loaded.allSatisfy { $0.contains("no longer offered") })

        let empty = resolve(SavedProduct(name: "P", lines: [
            SavedProductLine(type: "COMPONENT"), SavedProductLine(type: "STATIONERY")
        ]))
        XCTAssertEqual(empty.blockers.count, 2)
    }

    func testStationeryImageLinkMustBeHTTPS() {
        func blockers(_ url: String) -> [String] {
            resolve(SavedProduct(name: "P", lines: [SavedProductLine(type: "STATIONERY", reference: "slip-1", imageURL: url)]),
                    stationery: [slip]).blockers
        }
        XCTAssertEqual(blockers(""), [])
        XCTAssertEqual(blockers("https://example.com/logo.png"), [])
        XCTAssertEqual(blockers("http://example.com/logo.png").count, 1)
        XCTAssertEqual(blockers("https://").count, 1)
    }

    func testUnknownTypeBlocks() {
        let result = resolve(SavedProduct(name: "P", lines: [SavedProductLine(type: "GIFTWRAP", reference: "x")]))
        XCTAssertEqual(result.blockers.count, 1)
        XCTAssertTrue(result.blockers[0].contains("unknown item type"))
    }

    // MARK: SKUs

    func testSKULookupIgnoresCaseAndSurroundingSpaces() {
        let a = SavedProduct(name: "A", sku: "Kit-01")
        let b = SavedProduct(name: "B", sku: "")
        XCTAssertEqual(savedProduct(forSKU: " kit-01 ", in: [b, a])?.id, a.id)
        XCTAssertEqual(savedProduct(forSKU: "KIT-01", in: [a])?.id, a.id)
        XCTAssertNil(savedProduct(forSKU: "", in: [a, b]), "an empty SKU never matches a product without one")
        XCTAssertNil(savedProduct(forSKU: "   ", in: [a, b]))
        XCTAssertNil(savedProduct(forSKU: "kit-1", in: [a]))
    }

    func testSKUConflicts() {
        let a = SavedProduct(name: "Bracket", sku: "Kit-01")
        XCTAssertEqual(savedProductSKUConflict(" KIT-01", for: UUID(), in: [a]), "“Bracket” already uses SKU Kit-01.")
        XCTAssertNil(savedProductSKUConflict("kit-01", for: a.id, in: [a]), "a product doesn't conflict with itself")
        XCTAssertNil(savedProductSKUConflict("", for: UUID(), in: [a, SavedProduct(name: "B")]))
        XCTAssertNil(savedProductSKUConflict("Kit-02", for: UUID(), in: [a]))
    }

    // MARK: Storage

    func testCodableRoundTripKeepsOnlyReferences() throws {
        let product = SavedProduct(name: "Kit", sku: "K1", lines: [
            printLine(model: model(), reference: "file-new", quantity: 2),
            SavedProductLine(type: "STATIONERY", reference: "slip-1", quantity: 1, perOrder: true, imageURL: "https://example.com/a.png", name: "Slip")
        ])
        let data = try JSONEncoder().encode([product])
        XCTAssertEqual(try JSONDecoder().decode([SavedProduct].self, from: data), [product])
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [[String: Any]]).first
        XCTAssertEqual(Set(try XCTUnwrap(object).keys), ["id", "name", "sku", "lines", "created"])
        let lineKeys = Set(try XCTUnwrap((object?["lines"] as? [[String: Any]])?.first).keys)
        XCTAssertEqual(lineKeys, ["id", "type", "reference", "localModelID", "filamentID", "quantity", "perOrder", "imageURL", "name", "optionsJSON"])
    }

    func testDecodingToleratesMissingKeys() throws {
        let json = #"[{"name":"Old","lines":[{"type":"COMPONENT","reference":"box-1"}]}]"#
        let products = try JSONDecoder().decode([SavedProduct].self, from: Data(json.utf8))
        XCTAssertEqual(products.count, 1)
        XCTAssertEqual(products[0].sku, "")
        XCTAssertEqual(products[0].lines.first?.quantity, 1)
        XCTAssertEqual(products[0].lines.first?.perOrder, false)
        XCTAssertEqual(products[0].lines.first?.optionsJSON, "{}")
    }

    func testLoadSavedProductsHandlesMissingGarbageAndPartialFiles() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("SavedProductsTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent(savedProductsFileName)
        let backup = savedProductsBackupURL(for: url)
        XCTAssertEqual(backup.lastPathComponent, "products.unreadable.json")

        XCTAssertEqual(loadSavedProducts(from: url), [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: backup.path))

        try Data("not json".utf8).write(to: url)
        XCTAssertEqual(loadSavedProducts(from: url), [])
        XCTAssertEqual(try Data(contentsOf: backup), Data("not json".utf8), "an unreadable file is kept before it can be overwritten")
        try FileManager.default.removeItem(at: backup)

        let good = SavedProduct(name: "Good", lines: [SavedProductLine(type: "COMPONENT", reference: "box-1")])
        let goodJSON = String(decoding: try JSONEncoder().encode(good), as: UTF8.self)
        try Data("[\(goodJSON), {\"name\": 42}]".utf8).write(to: url)
        XCTAssertEqual(loadSavedProducts(from: url), [good], "one damaged entry doesn't discard the rest")
        XCTAssertTrue(FileManager.default.fileExists(atPath: backup.path))
        try FileManager.default.removeItem(at: backup)

        try JSONEncoder().encode([good]).write(to: url)
        XCTAssertEqual(loadSavedProducts(from: url), [good])
        XCTAssertFalse(FileManager.default.fileExists(atPath: backup.path), "a readable file makes no backup")
    }

    // MARK: Editor logic

    func testItemsSummary() {
        let bracket = model()
        let product = SavedProduct(name: "Kit", lines: [
            printLine(model: bracket, quantity: 1),
            SavedProductLine(type: "COMPONENT", reference: "box-1", quantity: 2),
            SavedProductLine(type: "STATIONERY", reference: "slip-1", quantity: 1, perOrder: true)
        ])
        XCTAssertEqual(savedProductItemsSummary(product, localModels: [bracket], filaments: [pla], components: [box], stationery: [slip]),
                       "1 × Bracket in PLA Black · 2 × Small box · Packing slip per order")
        // Catalogs not loaded: falls back to type names.
        XCTAssertEqual(savedProductItemsSummary(product, localModels: [], filaments: [], components: [], stationery: []),
                       "1 × 3D print · 2 × Component · Stationery per order")
        XCTAssertEqual(savedProductItemsSummary(SavedProduct(name: "E"), localModels: [], filaments: [], components: [], stationery: []), "No items")
        var named = product
        named.lines[0].name = "Left bracket"
        XCTAssertTrue(savedProductItemsSummary(named, localModels: [bracket], filaments: [pla], components: [], stationery: []).hasPrefix("1 × Left bracket in PLA Black"))
    }

    func testSaveBlockedReasons() {
        let bracket = model()
        let unuploaded = model("Clip", remoteID: nil)
        let existing = SavedProduct(name: "Other", sku: "SKU-1")
        func reason(_ product: SavedProduct) -> String? {
            savedProductSaveBlockedReason(product, in: [existing], localModels: [bracket, unuploaded])
        }
        let valid = SavedProduct(name: "Kit", lines: [printLine(model: bracket)])
        XCTAssertNil(reason(valid))
        XCTAssertNil(reason(SavedProduct(name: "Clip", lines: [printLine(model: unuploaded)])), "products can be saved before upload")
        XCTAssertNil(reason(SavedProduct(name: "Kit", lines: [printLine(model: bracket, filament: "petg-red")])), "out of stock is reported at use")
        XCTAssertEqual(reason(SavedProduct(name: "  ", lines: valid.lines)), "Enter a product name.")
        XCTAssertEqual(reason(SavedProduct(name: "Kit", sku: " sku-1 ", lines: valid.lines)), "“Other” already uses SKU SKU-1.")
        XCTAssertNil(reason(SavedProduct(id: existing.id, name: "Other", sku: "sku-1", lines: valid.lines)), "editing keeps its own SKU")
        XCTAssertEqual(reason(SavedProduct(name: "Kit")), "Add at least one item.")
        XCTAssertEqual(reason(SavedProduct(name: "Kit", lines: [printLine(model: nil)])), "Choose a model for the item.")
        XCTAssertEqual(reason(SavedProduct(name: "Kit", lines: [printLine(model: bracket, filament: " ")])), "Choose a material for the item.")
        XCTAssertNotNil(reason(SavedProduct(name: "Kit", lines: [printLine(model: model("Gone"))])))
        XCTAssertNil(reason(SavedProduct(name: "Kit", lines: [printLine(model: model("Gone"), reference: "file-old")])))
        XCTAssertEqual(reason(SavedProduct(name: "Kit", lines: [printLine(model: bracket), printLine(model: bracket, quantity: 0)])),
                       "Set a quantity from 1 to 10,000 for item 2.")
        XCTAssertNotNil(reason(SavedProduct(name: "Kit", lines: [printLine(model: bracket, quantity: 10_001)])))
        XCTAssertEqual(reason(SavedProduct(name: "Kit", lines: [SavedProductLine(type: "COMPONENT")])), "Choose a component for the item.")
        XCTAssertNotNil(reason(SavedProduct(name: "Kit", lines: [SavedProductLine(type: "STATIONERY", reference: "slip-1", imageURL: "ftp://x")])))
        XCTAssertNotNil(reason(SavedProduct(name: "Kit", lines: [SavedProductLine(type: "OTHER", reference: "x")])))
    }

    func testSavingTrimsDropsUnusedFieldsAndRefreshesSnapshot() {
        let bracket = model(remoteID: " file-new ")
        var stationeryLine = SavedProductLine(type: "STATIONERY", reference: " slip-1 ", filamentID: "pla-black", imageURL: " https://e.com/a.png ", name: " Slip ")
        stationeryLine.localModelID = UUID()
        let product = SavedProduct(name: "  Kit ", sku: " K1 ", lines: [printLine(model: bracket, reference: "file-old", filament: " pla-black "), stationeryLine])
        let saved = savedProductForSaving(product, localModels: [bracket])
        XCTAssertEqual(saved.name, "Kit")
        XCTAssertEqual(saved.sku, "K1")
        XCTAssertEqual(saved.lines[0].reference, "file-new")
        XCTAssertEqual(saved.lines[0].filamentID, "pla-black")
        XCTAssertEqual(saved.lines[0].localModelID, bracket.id)
        XCTAssertEqual(saved.lines[1].reference, "slip-1")
        XCTAssertEqual(saved.lines[1].filamentID, "")
        XCTAssertNil(saved.lines[1].localModelID)
        XCTAssertEqual(saved.lines[1].imageURL, "https://e.com/a.png")
        XCTAssertEqual(saved.lines[1].name, "Slip")
        // A model that isn't uploaded (or was removed) keeps the earlier snapshot.
        let notUploaded = model(remoteID: nil)
        XCTAssertEqual(savedProductForSaving(SavedProduct(name: "K", lines: [printLine(model: notUploaded, reference: "file-old")]),
                                             localModels: [notUploaded]).lines[0].reference, "file-old")
    }

    func testChangingTypeClearsChoicesAndStationeryDefaultsToPerOrder() {
        let line = printLine(model: model(), reference: "file-new")
        let stationery = savedProductLine(line, changingTypeTo: "STATIONERY")
        XCTAssertEqual(stationery.type, "STATIONERY")
        XCTAssertEqual(stationery.reference, "")
        XCTAssertNil(stationery.localModelID)
        XCTAssertEqual(stationery.filamentID, "")
        XCTAssertTrue(stationery.perOrder)
        XCTAssertEqual(stationery.quantity, line.quantity)
        XCTAssertFalse(savedProductLine(stationery, changingTypeTo: "COMPONENT").perOrder)
        XCTAssertEqual(savedProductLine(line, changingTypeTo: "PRINT"), line, "choosing the same type changes nothing")
    }

    func testSelectingModelSnapshotsItsUpload() {
        let uploaded = model(remoteID: "file-1")
        let local = model("Clip", remoteID: nil)
        let base = SavedProductLine(reference: "stale")
        XCTAssertEqual(savedProductLine(base, selectingModel: uploaded).reference, "file-1")
        XCTAssertEqual(savedProductLine(base, selectingModel: uploaded).localModelID, uploaded.id)
        XCTAssertEqual(savedProductLine(base, selectingModel: local).reference, "")
        XCTAssertEqual(savedProductLine(base, selectingModel: local).localModelID, local.id)
        XCTAssertNil(savedProductLine(base, selectingModel: nil).localModelID)
        XCTAssertEqual(savedProductLine(base, selectingModel: nil).reference, "")
    }

    func testPrefillFromModelPrefersPreparedMaterial() {
        var prepared = model("Prepared", remoteID: nil)
        prepared.printRecipe = PreparedPrintRecipe(sourceID: UUID(), sourceName: "src", intent: PartIntent(), orientation: .zUp,
                                                   materialID: "petg-red", created: Date())
        let product = savedProductPrefill(for: prepared, selectedFilamentID: "pla-black")
        XCTAssertEqual(product.name, "Prepared")
        XCTAssertEqual(product.sku, "")
        XCTAssertEqual(product.lines.count, 1)
        XCTAssertEqual(product.lines[0].type, "PRINT")
        XCTAssertEqual(product.lines[0].localModelID, prepared.id)
        XCTAssertEqual(product.lines[0].reference, "")
        XCTAssertEqual(product.lines[0].filamentID, "petg-red")
        XCTAssertEqual(product.lines[0].quantity, 1)
        XCTAssertFalse(product.lines[0].perOrder)

        let plain = model(remoteID: "file-1")
        let fromSelection = savedProductPrefill(for: plain, selectedFilamentID: "pla-black")
        XCTAssertEqual(fromSelection.lines[0].filamentID, "pla-black")
        XCTAssertEqual(fromSelection.lines[0].reference, "file-1")
    }

    func testDuplicateGetsNewIdentityNoSKUAndUniqueName() {
        let original = SavedProduct(name: "Kit", sku: "K1", lines: [SavedProductLine(type: "COMPONENT", reference: "box-1")])
        let firstCopy = savedProductDuplicate(original, in: [original])
        XCTAssertNotEqual(firstCopy.id, original.id)
        XCTAssertEqual(firstCopy.sku, "")
        XCTAssertEqual(firstCopy.name, "Kit copy")
        XCTAssertNotEqual(firstCopy.lines[0].id, original.lines[0].id)
        XCTAssertEqual(firstCopy.lines[0].reference, "box-1")
        XCTAssertNil(savedProductSKUConflict(firstCopy.sku, for: firstCopy.id, in: [original]))
        let secondCopy = savedProductDuplicate(original, in: [original, firstCopy])
        XCTAssertEqual(secondCopy.name, "Kit copy 2")
    }

    func testCatalogsToLoad() {
        XCTAssertEqual(savedProductCatalogsToLoad(lineTypes: ["STATIONERY", "PRINT", "COMPONENT"], loaded: []), [.materials, .components, .stationery])
        XCTAssertEqual(savedProductCatalogsToLoad(lineTypes: ["PRINT", "COMPONENT"], loaded: [.materials]), [.components])
        XCTAssertEqual(savedProductCatalogsToLoad(lineTypes: [], loaded: []), [])
    }

    func testSortedByNameThenCreated() {
        let early = Date(timeIntervalSince1970: 1)
        let late = Date(timeIntervalSince1970: 2)
        let products = [SavedProduct(name: "b", created: early), SavedProduct(name: "A", created: late), SavedProduct(name: "a", created: early)]
        XCTAssertEqual(savedProductsSorted(products).map(\.name), ["a", "A", "b"])
    }

    // MARK: Composer

    func testAddingToComposerReplacesOnlyAnUntouchedStarterLine() {
        let added = [OrderLine(type: "COMPONENT", reference: "box-1", quantity: 2)]
        // The starter line may carry a default material and quantity and still count as blank.
        let starter = OrderLine(reference: "", filamentID: "pla-black", quantity: 1)
        XCTAssertEqual(orderLinesAddingSavedProduct([starter], adding: added).map(\.reference), ["box-1"])

        let chosen = OrderLine(reference: "file-1", filamentID: "pla-black")
        XCTAssertEqual(orderLinesAddingSavedProduct([chosen], adding: added).map(\.reference), ["file-1", "box-1"])

        let named = OrderLine(name: "Gift note")
        XCTAssertEqual(orderLinesAddingSavedProduct([named], adding: added).count, 2)

        let withOptions = OrderLine(optionsJSON: #"{"infill":20}"#)
        XCTAssertEqual(orderLinesAddingSavedProduct([withOptions], adding: added).count, 2)

        XCTAssertEqual(orderLinesAddingSavedProduct([starter, starter], adding: added).count, 3, "two lines are never replaced")
        XCTAssertEqual(orderLinesAddingSavedProduct([], adding: added).count, 1)
        XCTAssertEqual(orderLinesAddingSavedProduct([chosen], adding: []).count, 1)
    }

    func testAddingAProductCountsAsUnsavedComposerInput() {
        let starter = OrderLine(reference: "", filamentID: "pla-black", quantity: 1)
        let lines = orderLinesAddingSavedProduct([starter], adding: [OrderLine(type: "COMPONENT", reference: "box-1")])
        XCTAssertTrue(orderComposerHasUnsavedInput(lines: lines, initialLines: [starter], delivery: DeliveryDetails(),
                                                   initialDelivery: DeliveryDetails(), metadataFields: [], paymentID: ""))
    }

    // MARK: Add Saved Product popover

    func testResolutionMarksOncePerOrderLines() {
        let bracket = model()
        let product = SavedProduct(name: "Kit", lines: [
            printLine(model: bracket, reference: "file-new", quantity: 2),
            SavedProductLine(type: "STATIONERY", reference: "slip-1", quantity: 1, perOrder: true)
        ])
        let result = resolve(product, units: 3, models: [bracket], stationery: [slip])
        XCTAssertEqual(result.perOrder, [false, true])
        XCTAssertEqual(result.perOrder.count, result.lines.count)
    }

    func testResolvedLinesSummaryShowsWhatIsAdded() {
        let bracket = model()
        let product = SavedProduct(name: "Kit", lines: [
            printLine(model: bracket, reference: "file-new", quantity: 2),
            SavedProductLine(type: "STATIONERY", reference: "slip-1", quantity: 1, perOrder: true)
        ])
        let lines = resolve(product, units: 3, models: [bracket], stationery: [slip]).lines
        XCTAssertEqual(savedProductResolvedLinesSummary(lines, localModels: [bracket], components: [], stationery: [slip]),
                       "6 × Bracket, 1 × Packing slip")
        // Catalogs and library not loaded: falls back to type names; an item name always wins.
        XCTAssertEqual(savedProductResolvedLinesSummary(lines, localModels: [], components: [], stationery: []), "6 × 3D print, 1 × Stationery")
        var named = lines
        named[0].name = "Left bracket"
        XCTAssertEqual(savedProductOrderLineTitle(named[0], localModels: [bracket], components: [], stationery: []), "Left bracket")
    }

    func testUnitsSoldParsesWhatIsTyped() {
        XCTAssertEqual(savedProductUnitsSold("3"), 3)
        XCTAssertEqual(savedProductUnitsSold(" 10000 "), 10_000)
        for text in ["", "0", "-1", "1.5", "3x", "10001", "1,000"] {
            XCTAssertNil(savedProductUnitsSold(text), text)
        }
    }
}
