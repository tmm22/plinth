import XCTest
@testable import Plinth

/// Saved Products › Check Cost…: parts, prerequisites, catalog prices, the per-unit sum and the delivery pointer.
final class ProductCostCheckTests: XCTestCase {
    private let pla = Record(values: ["id": "pla", "name": "PLA Black", "available": true])
    private let petg = Record(values: ["id": "petg", "name": "PETG Red", "available": false])

    private func printLine(model: LocalModel? = nil, reference: String = "", filament: String = "pla", quantity: Int = 1,
                           perOrder: Bool = false) -> SavedProductLine {
        var line = SavedProductLine()
        line.type = "PRINT"
        line.localModelID = model?.id
        line.reference = reference
        line.filamentID = filament
        line.quantity = quantity
        line.perOrder = perOrder
        return line
    }

    private func catalogLine(_ type: String, _ reference: String, quantity: Int = 1, perOrder: Bool = false) -> SavedProductLine {
        var line = SavedProductLine()
        line.type = type
        line.reference = reference
        line.quantity = quantity
        line.perOrder = perOrder
        return line
    }

    func testPrintsAreEstimatedAndCatalogItemsUseCatalogPrices() {
        let model = LocalModel(name: "Tidy", filePath: "/tmp/t.stl", remoteID: " f-new ")
        let product = SavedProduct(name: "Desk Tidy", lines: [
            printLine(model: model, reference: "f-old", quantity: 2),
            catalogLine("COMPONENT", "feet", quantity: 1),
            catalogLine("STATIONERY", "slip", quantity: 1, perOrder: true),
        ])
        let components = [Record(values: ["id": "feet", "name": "Adhesive Feet", "price": 0.5, "priceUnit": "USD"])]
        let stationery = [Record(values: ["id": "slip", "name": "Packing slip", "price": "0.25"])]
        let parts = productCostParts(product, units: 3, localModels: [model], filaments: [pla], components: components,
                                     stationery: stationery, loadedCatalogs: [.components, .stationery])
        XCTAssertEqual(parts.count, 3)
        XCTAssertEqual(parts[0].state, .waiting)
        XCTAssertEqual(parts[0].fileID, "f-new", "the linked model's latest upload wins")
        XCTAssertEqual(parts[0].filamentID, "pla")
        XCTAssertEqual(parts[0].quantity, 6)
        XCTAssertEqual(parts[0].title, "Tidy in PLA Black")
        XCTAssertEqual(parts[1].quantity, 3)
        XCTAssertEqual(parts[1].state.total, Decimal(string: "1.5"))
        XCTAssertEqual(parts[2].quantity, 1, "once per order")
        XCTAssertEqual(parts[2].state.total, Decimal(string: "0.25"))

        var priced = parts
        priced[0].state = .priced(total: Decimal(string: "59.58")!, detail: "Slant estimate for 6")
        let summary = productCostSummary(priced, units: 3)
        XCTAssertTrue(summary.complete)
        XCTAssertEqual(summary.total, Decimal(string: "61.33"))
        XCTAssertEqual(summary.perUnit, Decimal(string: "20.44"), "61.33 ÷ 3 = 20.443…")
        XCTAssertEqual(productCostPerUnitText(summary), "$20.44 per unit")
    }

    func testMissingPrerequisitesAreExplainedNotGuessed() {
        let notUploaded = LocalModel(name: "Bracket", filePath: "/tmp/b.stl")
        let removedID = UUID()
        var removed = printLine(reference: "")
        removed.localModelID = removedID
        let product = SavedProduct(name: "Kit", lines: [
            printLine(model: notUploaded),
            removed,
            printLine(reference: "f1", filament: ""),
            printLine(reference: "f1", filament: "gone"),
            printLine(reference: "f1", filament: "petg"),
            catalogLine("COMPONENT", "feet"),
            catalogLine("STATIONERY", "slip"),
            catalogLine("STATIONERY", "card"),
            catalogLine("WIDGET", "x"),
        ])
        let stationery = [Record(values: ["id": "card", "name": "Card", "price": NSNull()])]
        let parts = productCostParts(product, units: 1, localModels: [notUploaded], filaments: [pla, petg], components: [],
                                     stationery: stationery, loadedCatalogs: [.stationery])
        func reason(_ index: Int) -> String? { if case .unavailable(let text) = parts[index].state { return text }; return nil }
        XCTAssertEqual(reason(0), "“Bracket” isn’t uploaded to Slant. Upload it from Models to price it.")
        XCTAssertEqual(reason(1), "Its model is no longer in your library. Edit the product to choose another.")
        XCTAssertEqual(reason(2), "Choose a material for this item.")
        XCTAssertEqual(reason(3), "Its material is no longer offered. Edit the product to choose another.")
        XCTAssertEqual(reason(4), "Its material is out of stock, so Slant can’t print it now.")
        XCTAssertEqual(reason(5), "Load Components in Catalog to include its price.")
        XCTAssertEqual(reason(6), "It’s no longer offered in the catalog.")
        XCTAssertEqual(reason(7), "Slant lists no price for it.")
        XCTAssertEqual(reason(8), "This item has an unknown type.")
        let summary = productCostSummary(parts, units: 1)
        XCTAssertFalse(summary.complete)
        XCTAssertEqual(summary.pricedCount, 0)
    }

    func testUnloadedMaterialsStillEstimateAndOversizeIsRefused() {
        let product = SavedProduct(name: "Big", lines: [printLine(reference: "f1", quantity: 5000)])
        let one = productCostParts(product, units: 2, localModels: [], filaments: [], components: [], stationery: [], loadedCatalogs: [])
        XCTAssertEqual(one[0].state, .waiting, "Slant checks the material when the catalog isn't loaded")
        XCTAssertEqual(one[0].quantity, 10_000)
        let three = productCostParts(product, units: 3, localModels: [], filaments: [], components: [], stationery: [], loadedCatalogs: [])
        XCTAssertEqual(three[0].state, .unavailable("More than 10,000 of this item. Choose fewer units."))
        let overflow = productCostParts(SavedProduct(name: "X", lines: [printLine(reference: "f1", quantity: Int.max)]), units: 2,
                                        localModels: [], filaments: [], components: [], stationery: [], loadedCatalogs: [])
        XCTAssertEqual(overflow[0].state, .unavailable("More than 10,000 of this item. Choose fewer units."))
    }

    func testEstimateCountIsCapped() {
        let product = SavedProduct(name: "Many", lines: (0..<(productCostMaxEstimates + 2)).map { printLine(reference: "f\($0)") })
        let parts = productCostParts(product, units: 1, localModels: [], filaments: [pla], components: [], stationery: [], loadedCatalogs: [])
        XCTAssertEqual(parts.filter { $0.state == .waiting }.count, productCostMaxEstimates)
        XCTAssertEqual(parts.last?.state, .unavailable("Plinth estimates up to 20 prints in one check."))
    }

    func testCatalogPriceNeedsUSD() {
        XCTAssertEqual(try? productCostCatalogPrice(Record(values: ["price": "1.20"])).get(), Decimal(string: "1.2"))
        XCTAssertEqual(try? productCostCatalogPrice(Record(values: ["price": 1, "priceUnit": "usd"])).get(), Decimal(1))
        XCTAssertNil(try? productCostCatalogPrice(Record(values: ["price": 1, "priceUnit": "EUR"])).get())
        XCTAssertNil(try? productCostCatalogPrice(Record(values: ["price": -1])).get())
        XCTAssertNil(try? productCostCatalogPrice(Record(values: ["price": true])).get())
        XCTAssertNil(try? productCostCatalogPrice(Record(values: [:])).get())
    }

    func testPartialSummaryAndDetails() {
        let parts = [
            ProductCostPart(id: 0, type: "PRINT", title: "A", quantity: 1, perOrder: false, state: .priced(total: Decimal(string: "9.93")!, detail: "")),
            ProductCostPart(id: 1, type: "PRINT", title: "B", quantity: 1, perOrder: false, state: .failed("Refused")),
        ]
        let summary = productCostSummary(parts, units: 1)
        XCTAssertFalse(summary.complete)
        XCTAssertEqual(productCostPerUnitText(summary), "At least $9.93 per unit")
        XCTAssertFalse(productCostSummary([], units: 1).complete)
        XCTAssertEqual(productCostEstimateDetail(ComparisonPrice(total: Decimal(string: "19.86")!, quantity: 2, perUnit: Decimal(string: "9.93")!)),
                       "Slant estimate for 2, $9.93 each")
        XCTAssertEqual(productCostEstimateDetail(ComparisonPrice(total: 5, quantity: 1, perUnit: 5)), "Slant estimate")
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        cal.locale = Locale(identifier: "en_GB")
        XCTAssertTrue(productCostCheckedText(Date(timeIntervalSince1970: 0), calendar: cal).hasPrefix("Checked 1 Jan 1970"))
    }

    func testDeliveryHintFromOrdersWithTheProduct() {
        let model = LocalModel(name: "Tidy", filePath: "/tmp/t.stl", remoteID: "f1")
        let product = SavedProduct(name: "Desk Tidy", sku: "TIDY", lines: [printLine(model: model)])
        func order(_ id: String, status: String = "SHIPPED", file: String, sku: Any = NSNull(), country: String, delivery: String) -> Record {
            Record(values: ["publicId": id, "status": status, "createdAt": "2026-10-01T00:00:00Z", "deliveryCost": delivery,
                            "items": [["type": "PRINT", "publicFileServiceId": file, "quantity": 1, "SKU": sku]],
                            "customer": ["details": ["address": ["country": country]]]])
        }
        let orders = [
            order("A", file: "f1", country: "AU", delivery: "30.00"),
            order("B", file: "f9", sku: "tidy", country: "AU", delivery: "20.00"),
            order("C", file: "f1", country: "GB", delivery: "12.00"),
            order("D", file: "f2", country: "GB", delivery: "15.00"),
            order("E", file: "f2", country: "GB", delivery: "15.00"),
            order("F", status: "DRAFT", file: "f1", country: "GB", delivery: "15.00"),
            order("G", status: "DRAFT", file: "f1", country: "GB", delivery: "15.00"),
        ]
        let hint = productDeliveryHint(product, localModels: [model], orders: orders)
        XCTAssertEqual(hint, ProductDeliveryHint(countryCode: "AU", orders: 2, average: 25), "drafts and other products don't count")
        XCTAssertTrue(productDeliveryHintText(hint).contains("$25.00 on average"))
        XCTAssertNil(productDeliveryHint(SavedProduct(name: "None", lines: [printLine(reference: "zz")]), localModels: [], orders: orders))
        XCTAssertTrue(productDeliveryHintText(nil).hasPrefix("Delivery isn’t included"))
    }
}
