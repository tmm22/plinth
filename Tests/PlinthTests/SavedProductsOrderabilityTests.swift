import XCTest
@testable import Plinth

/// Saved products that can't be ordered right now (SavedProducts.swift): read-only, from the loaded catalogs.
extension SavedProductsTests {
    func testOrderabilityNamesTheResolversReasons() {
        let bracket = model()
        let fine = SavedProduct(name: "Fine", lines: [printLine(model: bracket)])
        let outOfStock = SavedProduct(name: "Red", lines: [printLine(model: bracket, filament: "petg-red")])
        let state = savedProductOrderability(outOfStock, localModels: [bracket], filaments: [pla, petgOut], components: [], stationery: [])
        XCTAssertEqual(state.blockers, ["PETG Red is out of stock."])
        XCTAssertFalse(state.canOrder)
        XCTAssertEqual(state.uncheckedCatalogs, [])
        XCTAssertEqual(savedProductCantOrderText(state), "Can’t be ordered: PETG Red is out of stock.")

        let ok = savedProductOrderability(fine, localModels: [bracket], filaments: [pla, petgOut], components: [], stationery: [])
        XCTAssertTrue(ok.canOrder)
        XCTAssertNil(savedProductCantOrderText(ok))

        // Several reasons: the first, and how many more.
        let notUploaded = model("Hook", remoteID: nil)
        let twoProblems = SavedProduct(name: "Two", lines: [printLine(model: notUploaded), printLine(model: bracket, filament: "gone")])
        let both = savedProductOrderability(twoProblems, localModels: [bracket, notUploaded], filaments: [pla], components: [], stationery: [])
        XCTAssertEqual(both.blockers.count, 2)
        XCTAssertEqual(savedProductCantOrderText(both), "Can’t be ordered: \(both.blockers[0]) (+1 more)")
        XCTAssertTrue(both.blockers[1].contains("no longer offered"))
    }

    func testUnloadedCatalogsAreReportedNotTreatedAsFine() {
        let bracket = model()
        let kit = SavedProduct(name: "Kit", lines: [
            printLine(model: bracket),
            SavedProductLine(type: "COMPONENT", reference: "box-1"),
            SavedProductLine(type: "STATIONERY", reference: "slip-1", perOrder: true),
        ])
        // Nothing loaded: the resolver never blocks on an empty catalog, so each is reported as unchecked.
        let state = savedProductOrderability(kit, localModels: [bracket], filaments: [], components: [], stationery: [])
        XCTAssertTrue(state.canOrder)
        XCTAssertEqual(state.uncheckedCatalogs, [.materials, .components, .stationery])
        XCTAssertEqual(savedProductsUncheckedCatalogsText(state.uncheckedCatalogs, loaded: []),
                       "Stock and availability weren’t checked for materials, components and stationery, because those catalogs aren’t loaded.")
        // Partly loaded: only the missing ones, and an empty loaded catalog is named for what it is.
        let partial = savedProductOrderability(kit, localModels: [bracket], filaments: [pla], components: [], stationery: [])
        XCTAssertEqual(partial.uncheckedCatalogs, [.components, .stationery])
        XCTAssertEqual(savedProductsUncheckedCatalogsText(partial.uncheckedCatalogs, loaded: [.materials, .stationery]),
                       "Stock and availability weren’t checked for components, because that catalog isn’t loaded. Stock and availability weren’t checked for stationery, because Slant listed none.")
        // Order doesn't depend on how the kinds were gathered (the sheet unions them through a Set).
        XCTAssertEqual(savedProductsUncheckedCatalogsText([.stationery, .materials], loaded: []),
                       "Stock and availability weren’t checked for materials and stationery, because those catalogs aren’t loaded.")
        XCTAssertNil(savedProductsUncheckedCatalogsText([], loaded: []))

        // Everything loaded and present: nothing unchecked.
        let all = savedProductOrderability(kit, localModels: [bracket], filaments: [pla], components: [box], stationery: [slip])
        XCTAssertEqual(all.uncheckedCatalogs, [])
        XCTAssertTrue(all.canOrder)
        // A catalog item no longer offered blocks once its catalog is loaded.
        let gone = savedProductOrderability(kit, localModels: [bracket], filaments: [pla], components: [Record(values: ["id": "other"])], stationery: [slip])
        XCTAssertFalse(gone.canOrder)
    }

    func testUncheckedOnlyForCatalogsTheProductUses() {
        // A print line without a material is a blocker of its own, not an unchecked catalog.
        let noMaterial = SavedProduct(name: "P", lines: [printLine(model: model(), filament: "")])
        let state = savedProductOrderability(noMaterial, localModels: [model()], filaments: [], components: [], stationery: [])
        XCTAssertEqual(state.uncheckedCatalogs, [])
        XCTAssertFalse(state.canOrder)
        // A product with no items can't be ordered.
        XCTAssertFalse(savedProductOrderability(SavedProduct(name: "Empty"), localModels: [], filaments: [], components: [], stationery: []).canOrder)
        // Multi-unit and per-order lines: checked for one unit, so a valid product never trips the 10,000 cap here.
        let bracket = model()
        let big = SavedProduct(name: "Big", lines: [printLine(model: bracket, quantity: 10_000),
                                                    SavedProductLine(type: "STATIONERY", reference: "slip-1", quantity: 1, perOrder: true)])
        XCTAssertTrue(savedProductOrderability(big, localModels: [bracket], filaments: [pla], components: [], stationery: [slip]).canOrder)
    }

    func testCountAndPickerTitles() {
        XCTAssertNil(savedProductsCantOrderCountText(0))
        XCTAssertEqual(savedProductsCantOrderCountText(1), "1 product can’t be ordered right now.")
        XCTAssertEqual(savedProductsCantOrderCountText(2), "2 products can’t be ordered right now.")
        let product = SavedProduct(name: " Shelf ", sku: " S-1 ")
        XCTAssertEqual(savedProductPickerTitle(product, canOrder: true), "Shelf (S-1)")
        XCTAssertEqual(savedProductPickerTitle(product, canOrder: false), "Shelf (S-1) — can’t be ordered")
        XCTAssertEqual(savedProductPickerTitle(SavedProduct(name: ""), canOrder: true), "Untitled product")
    }
}
