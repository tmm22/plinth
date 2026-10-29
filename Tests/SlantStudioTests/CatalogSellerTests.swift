import XCTest
@testable import SlantStudio

final class CatalogSellerTests: XCTestCase {
    // MARK: Catalog search by category

    let categories = [
        Record(values: ["id": "hw", "name": "Hardware", "slug": "hardware", "parentId": NSNull()]),
        Record(values: ["id": "mag", "name": "Magnets", "slug": "magnets", "parentId": "hw"])
    ]

    func testComponentMatchesItsCategoryAndParentNames() {
        let magnet = Record(values: ["id": "SL004", "name": "Neodymium disc 6x2", "categoryId": "mag", "tags": ["n52"]])
        XCTAssertTrue(catalogRecordMatches(magnet, search: "magnets", categories: categories))
        XCTAssertTrue(catalogRecordMatches(magnet, search: " Magnet ", categories: categories))
        XCTAssertTrue(catalogRecordMatches(magnet, search: "hardware", categories: categories))
        XCTAssertTrue(catalogRecordMatches(magnet, search: "n52", categories: categories))
        XCTAssertFalse(catalogRecordMatches(magnet, search: "fasteners", categories: categories))
        // Without loaded categories only the record's own fields are searched.
        XCTAssertFalse(catalogRecordMatches(magnet, search: "magnets"))
        XCTAssertTrue(catalogRecordMatches(magnet, search: "neodymium"))
        // An unknown category ID is ignored rather than matched.
        XCTAssertFalse(catalogRecordMatches(Record(values: ["name": "Clip", "categoryId": "gone"]), search: "gone", categories: categories))
    }

    func testSearchFieldsKeepNamedCategoriesAndSkipEmptyValues() {
        let record = Record(values: ["name": "Box", "category": "Packaging", "description": NSNull()])
        XCTAssertEqual(catalogSearchFields(record), ["Box", "Packaging"])
    }

    // MARK: Stationery facts

    func testStationeryFactRowsShowOnlyWhatSlantSends() {
        let card = Record(values: [
            "id": "st-1", "name": "Thank-you card", "price": 0.25, "weight": 3.5,
            "dimensions": "105 x 148", "quantity": 1, "available": true
        ])
        let rows = stationeryFactRows(card)
        XCTAssertEqual(rows.map(\.0), ["Price", "Dimensions", "Weight", "Quantity"])
        XCTAssertEqual(rows.map(\.1), ["$0.25", "105 x 148", "3.5", "1"])

        let withUnits = Record(values: ["dimensions": "4 x 6", "dimensionUnit": "in", "weight": 12, "weightUnit": "g",
                                        "price": "1.5", "priceUnit": "USD"])
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: stationeryFactRows(withUnits)),
                       ["Dimensions": "4 x 6", "Weight": "12 g", "Price": "$1.50"], "Slant's dimensions text is shown as written, never with dimensionUnit added")
    }

    func testStationeryFactRowsTolerateNullsAndOddTypes() {
        let odd = Record(values: [
            "price": NSNull(), "weight": true, "dimensions": 42, "quantity": 2.5, "description": NSNull(), "available": false
        ])
        XCTAssertEqual(stationeryFactRows(odd).map(\.0), ["Availability"])
        XCTAssertEqual(stationeryFactRows(Record(values: [:])).count, 0)
        XCTAssertEqual(stationeryFactRows(Record(values: ["price": "free", "weight": -1, "quantity": 0])).count, 0)
        XCTAssertEqual(stationeryFactRows(Record(values: ["quantity": 50_000]))[0].1, 50_000.formatted())
    }

    func testCatalogNumberText() {
        XCTAssertEqual(catalogNumberText(3.5), "3.5")
        XCTAssertEqual(catalogNumberText(3.0), "3")
        XCTAssertEqual(catalogNumberText(0.1 + 0.2), "0.3")
        XCTAssertEqual(catalogNumberText(" 12 "), "12")
        XCTAssertEqual(catalogNumberText(1234567.891), "1234567.89")
        XCTAssertNil(catalogNumberText(true))
        XCTAssertNil(catalogNumberText(Double.nan))
        XCTAssertNil(catalogNumberText(-2))
        XCTAssertNil(catalogNumberText(nil))
        XCTAssertNil(catalogNumberText(NSNull()))
        XCTAssertEqual(catalogWholeNumber(4.0), 4)
        XCTAssertNil(catalogWholeNumber(4.2))
        XCTAssertNil(catalogWholeNumber(false))
        XCTAssertEqual(catalogWholeNumber("7"), 7)
    }

    func testStationeryCardSubtitle() {
        XCTAssertEqual(stationeryCardSubtitle(Record(values: ["description": "  A6 card ", "dimensions": "105 x 148"])), "A6 card")
        XCTAssertEqual(stationeryCardSubtitle(Record(values: ["description": "", "dimensions": "105 x 148"])), "105 x 148")
        XCTAssertEqual(stationeryCardSubtitle(Record(values: ["description": NSNull()])), "Stationery")
    }

    func testComponentWeightGainsItsUnitWhenNumeric() {
        let rows = Dictionary(uniqueKeysWithValues: componentFactRows(Record(values: ["weight": 3.5, "weightUnit": "g"])))
        XCTAssertEqual(rows["Weight"], "3.5 g")
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: componentFactRows(Record(values: ["weight": 3.5])))["Weight"], "3.5")
    }

    // MARK: Material names

    func testMaterialDisplayNameTitleCasesCapitalsAndKeepsAcronyms() {
        XCTAssertEqual(materialDisplayName("PLA BLACK"), "PLA Black")
        XCTAssertEqual(materialDisplayName("PETG MATTE WHITE"), "PETG Matte White")
        XCTAssertEqual(materialDisplayName("OPM GREY"), "OPM Grey")
        XCTAssertEqual(materialDisplayName("PETG-CF BLACK"), "PETG-CF Black")
        XCTAssertEqual(materialDisplayName("TPU 95A RED"), "TPU 95A Red")
        XCTAssertEqual(materialDisplayName("PLA+ SILK GOLD"), "PLA+ Silk Gold")
        XCTAssertEqual(materialDisplayName("GLOW-IN-THE-DARK PLA"), "Glow-In-The-Dark PLA")
        XCTAssertEqual(materialDisplayName("1KG PLA  BLUE"), "1KG PLA  Blue")
        // Already cased, empty or letterless names are left alone.
        XCTAssertEqual(materialDisplayName("PLA Black"), "PLA Black")
        XCTAssertEqual(materialDisplayName("matte black"), "matte black")
        XCTAssertEqual(materialDisplayName(""), "")
        XCTAssertEqual(materialDisplayName("123"), "123")
        XCTAssertEqual(materialDisplayName("ÉCRU PLA"), "Écru PLA")
    }

    func testMaterialNamesChangeOnlyForDisplay() {
        let material = Record(values: ["publicId": "pla-black-id", "name": "PLA BLACK", "profile": "PLA", "available": false])
        XCTAssertEqual(catalogRecordTitle(material, kind: .materials), "PLA Black")
        XCTAssertEqual(filamentPickerLabel(material), "PLA Black · Out of stock")
        XCTAssertEqual(material.id, "pla-black-id")
        XCTAssertEqual(material.name, "PLA BLACK")
        XCTAssertTrue(catalogRecordMatches(material, search: "pla black"))
        XCTAssertEqual(catalogRecordTitle(Record(values: ["name": "USB CABLE"]), kind: .components), "USB CABLE")
        XCTAssertEqual(catalogRecordTitle(Record(values: [:]), kind: .stationery), "Untitled stationery")
    }

    // MARK: Same-named models

    func testDuplicateNameDetailsUseFewestFacts() {
        let names = ["sample-cube", "Sample-Cube ", "bracket", "sample-cube"]
        let parts = [["STL", "1 Oct", "10:00"], ["OBJ", "1 Oct", "10:00"], ["STL", "2 Oct", "09:00"], ["STL", "3 Oct", "10:00"]]
        XCTAssertEqual(duplicateNameDetails(names: names, parts: parts), ["STL · 1 Oct", "OBJ · 1 Oct", nil, "STL · 3 Oct"])
        XCTAssertEqual(duplicateNameDetails(names: ["a", "b"], parts: [["STL"], ["STL"]]), [nil, nil])
        XCTAssertEqual(duplicateNameDetails(names: ["a", "a"], parts: [["STL"], ["OBJ"]]), ["STL", "OBJ"])
    }

    func testDuplicateNameDetailsNumberEntriesThatStayAlike() {
        let names = ["cube", "cube", "cube"]
        XCTAssertEqual(duplicateNameDetails(names: names, parts: [["STL", "1 Oct"], ["STL", "1 Oct"], ["OBJ", "1 Oct"]]),
                       ["STL · 1 Oct · 1 of 2", "STL · 1 Oct · 2 of 2", "OBJ · 1 Oct"])
        XCTAssertEqual(duplicateNameDetails(names: ["x", "x"], parts: [[], [" "]]), ["1 of 2", "2 of 2"])
        XCTAssertEqual(duplicateNameDetails(names: ["x", "x"], parts: [[]]), [nil, nil])
        XCTAssertEqual(duplicateNameDetails(names: [], parts: []), [])
    }

    func testDuplicateNameFactsAreOnlyAskedForSharedNames() {
        var asked: [Int] = []
        let details = duplicateNameDetails(names: ["a", "b", "A", "c"]) { index in
            asked.append(index)
            return ["#\(index)"]
        }
        XCTAssertEqual(details, ["#0", nil, "#2", nil])
        XCTAssertEqual(asked, [0, 2])
    }

    func testLocalModelDetailsUseFormatThenDateThenTime() {
        let day = Date(timeIntervalSince1970: 1_800_000_000)
        let a = LocalModel(name: "sample-cube", filePath: "/tmp/a.stl", added: day)
        let b = LocalModel(name: "sample-cube", filePath: "/tmp/b.stl", added: day.addingTimeInterval(60))
        let c = LocalModel(name: "sample-cube", filePath: "/tmp/c.3mf", added: day)
        let d = LocalModel(name: "unique", filePath: "/tmp/d.stl", added: day)
        let details = localModelDuplicateNameDetails([a, b, c, d], day: { _ in "23 Oct 2026" },
                                                     time: { $0 == day ? "10:00" : "10:01" })
        XCTAssertEqual(details[a.id], "STL · 23 Oct 2026 · 10:00")
        XCTAssertEqual(details[b.id], "STL · 23 Oct 2026 · 10:01")
        XCTAssertEqual(details[c.id], "3MF · 23 Oct 2026 · 10:00")
        XCTAssertNil(details[d.id])
    }

    func testCloudRecordDetailsFallBackToTheIDEnd() {
        let files = [
            Record(values: ["publicFileServiceId": "file-aaaa111111", "name": "sample-cube", "type": "stl", "createdAt": "2026-10-20T09:00:00Z"]),
            Record(values: ["publicFileServiceId": "file-bbbb222222", "name": "sample-cube", "type": "stl", "createdAt": "2026-10-20T09:00:00Z"]),
            Record(values: ["publicFileServiceId": "file-cccc333333", "name": "other"])
        ]
        let details = recordDuplicateNameDetails(files, day: { _ in "20 Oct" }, time: { _ in "09:00" })
        XCTAssertEqual(details, ["STL · 20 Oct · 09:00 · ID …111111", "STL · 20 Oct · 09:00 · ID …222222", nil])
        XCTAssertEqual(recordDuplicateNameDetailsByID(files).count, 2)
        XCTAssertEqual(nameWithDetail("sample-cube", "STL"), "sample-cube — STL")
        XCTAssertEqual(nameWithDetail("sample-cube", nil), "sample-cube")
        XCTAssertEqual(nameWithDetail("sample-cube", ""), "sample-cube")
    }

    // MARK: Seller address storage

    private func temporaryFile() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return folder.appendingPathComponent(sellerAddressFileName)
    }

    let ada = SellerAddress(name: "Ada Lovelace", email: "ada@example.com", country: "GB", line1: "12 St James's Square",
                            line2: "Flat 2", city: "London", state: "", zip: "SW1Y 4JH")

    func testLoadingIsLenientAndKeepsUnreadableFiles() throws {
        let url = try temporaryFile()
        XCTAssertNil(loadSellerAddress(from: url))

        try Data(#"{"name":"  Ada ","zip":12345,"country":"us","city":7.5,"extra":true}"#.utf8).write(to: url)
        let loaded = try XCTUnwrap(loadSellerAddress(from: url))
        XCTAssertEqual(loaded.name, "Ada")
        XCTAssertEqual(loaded.zip, "12345")
        XCTAssertEqual(loaded.country, "US")
        XCTAssertEqual(loaded.city, "")

        try Data(#"{"country":"GB"}"#.utf8).write(to: url)
        XCTAssertNil(loadSellerAddress(from: url), "Only a country is no address")

        try Data("not json".utf8).write(to: url)
        XCTAssertNil(loadSellerAddress(from: url))
        XCTAssertEqual(try Data(contentsOf: sellerAddressBackupURL(for: url)), Data("not json".utf8))
        XCTAssertEqual(sellerAddressBackupURL(for: url).lastPathComponent, "seller-address.unreadable.json")
    }

    func testRoundTripThroughJSON() throws {
        let url = try temporaryFile()
        try JSONEncoder().encode(ada).write(to: url)
        XCTAssertEqual(loadSellerAddress(from: url), ada)
    }

    func testSaveNeedsADraftReadyAddress() {
        XCTAssertNil(sellerAddressSaveBlockedReason(ada))
        var address = ada
        address.email = "ada@"
        XCTAssertEqual(sellerAddressSaveBlockedReason(address), "Enter an email like name@example.com.")
        address = ada
        address.country = "US"
        XCTAssertEqual(sellerAddressSaveBlockedReason(address), "Enter your state or province.")
        address.state = " NY "
        XCTAssertNil(sellerAddressSaveBlockedReason(address))
        address.country = "EU"
        XCTAssertEqual(sellerAddressSaveBlockedReason(address), "Choose your country.")
        address.country = ""
        XCTAssertEqual(sellerAddressSaveBlockedReason(address), "Choose your country.")
        XCTAssertEqual(sellerAddressSaveBlockedReason(SellerAddress()), "Enter your name.")
        address = ada
        address.zip = "  "
        XCTAssertEqual(sellerAddressSaveBlockedReason(address), "Enter your postal code.")
    }

    func testInitialDraftAndSaveState() {
        XCTAssertEqual(sellerAddressInitialDraft(saved: nil, regionDefault: ("GB", "")).country, "GB")
        XCTAssertEqual(sellerAddressInitialDraft(saved: nil, regionDefault: (orderCountryOtherTag, "SE")).country, "SE")
        XCTAssertEqual(sellerAddressInitialDraft(saved: nil, regionDefault: ("", "")).country, "", "Never assume a country")
        XCTAssertEqual(sellerAddressInitialDraft(saved: ada, regionDefault: ("US", "")), ada)
        XCTAssertTrue(sellerAddressCanSave(ada, saved: nil))
        XCTAssertFalse(sellerAddressCanSave(ada, saved: ada))
        var padded = ada
        padded.city = " London "
        XCTAssertFalse(sellerAddressCanSave(padded, saved: ada), "Only spaces differ")
        padded.city = "Bath"
        XCTAssertTrue(sellerAddressCanSave(padded, saved: ada))
        XCTAssertEqual(sellerAddressSummary(ada), "Ada Lovelace, London, GB")
    }

    // MARK: Use My Address

    func testSellerAddressFillsTheComposerFields() {
        let delivery = deliveryDetails(fromSellerAddress: ada)
        XCTAssertEqual(delivery.name, "Ada Lovelace")
        XCTAssertEqual(delivery.email, "ada@example.com")
        XCTAssertEqual(delivery.line2, "Flat 2")
        XCTAssertEqual(delivery.countrySelection, "GB")
        XCTAssertEqual(orderCountryPickerValue(delivery), "GB")
        var swedish = ada
        swedish.country = "se"
        let other = deliveryDetails(fromSellerAddress: swedish)
        XCTAssertEqual(other.countrySelection, orderCountryOtherTag)
        XCTAssertEqual(orderCountryPickerValue(other), "SE")
    }

    func testUseMyAddressAsksBeforeReplacingEnteredDetails() {
        let mine = deliveryDetails(fromSellerAddress: ada)
        var blank = DeliveryDetails()
        blank.countrySelection = "US"
        XCTAssertFalse(useMyAddressNeedsConfirmation(current: blank, replacement: mine), "A default country alone isn't entered")
        XCTAssertFalse(useMyAddressNeedsConfirmation(current: mine, replacement: mine))
        var typed = blank
        typed.name = "A customer"
        XCTAssertTrue(useMyAddressNeedsConfirmation(current: typed, replacement: mine))
        var unitOnly = blank
        unitOnly.line2 = "Unit 4"
        XCTAssertTrue(useMyAddressNeedsConfirmation(current: unitOnly, replacement: mine))
    }

    func testUseMyAddressAsksBeforeReplacingAPickedCountry() {
        let mine = deliveryDetails(fromSellerAddress: ada) // GB
        var blank = DeliveryDetails()
        blank = deliveryApplyingCountryPick("US", to: blank)
        XCTAssertFalse(useMyAddressNeedsConfirmation(current: blank, replacement: mine, countryPicked: false),
                       "the region default still doesn't count")
        XCTAssertTrue(useMyAddressNeedsConfirmation(current: blank, replacement: mine, countryPicked: true),
                      "a country the seller chose counts as entered")
        let sameCountry = deliveryApplyingCountryPick("GB", to: DeliveryDetails())
        XCTAssertFalse(useMyAddressNeedsConfirmation(current: sameCountry, replacement: mine, countryPicked: true),
                       "nothing is lost when the address keeps the chosen country")
        XCTAssertFalse(useMyAddressNeedsConfirmation(current: mine, replacement: mine, countryPicked: true))
    }

    // MARK: Order a Sample to Me…

    func testSampleOrderBlockedReasons() {
        XCTAssertEqual(sampleOrderBlockedReason(fileID: nil, draftBlockedReason: nil, composerOpen: false, busy: false), "Upload this model first.")
        XCTAssertEqual(sampleOrderBlockedReason(fileID: " ", draftBlockedReason: nil, composerOpen: false, busy: false), "Upload this model first.")
        XCTAssertEqual(sampleOrderBlockedReason(fileID: "f", draftBlockedReason: "Connect your account first.", composerOpen: false, busy: false),
                       "Connect your account first.")
        XCTAssertEqual(sampleOrderBlockedReason(fileID: "f", draftBlockedReason: nil, composerOpen: true, busy: false),
                       "Finish or close the open order draft first.")
        XCTAssertEqual(sampleOrderBlockedReason(fileID: "f", draftBlockedReason: nil, composerOpen: false, busy: true), "Working…")
        XCTAssertNil(sampleOrderBlockedReason(fileID: "f", draftBlockedReason: nil, composerOpen: false, busy: false))
    }

    func testSamplePrefillIsOneUnitToTheSellerForReview() throws {
        let prefill = sampleOrderPrefill(fileID: "file-1", filamentID: "", defaultFilamentID: "pla-black", address: ada)
        XCTAssertTrue(prefill.usesSellerAddress)
        XCTAssertNil(prefill.sourceOrderNumber)
        XCTAssertEqual(prefill.lines.count, 1)
        XCTAssertEqual(prefill.lines[0].type, "PRINT")
        XCTAssertEqual(prefill.lines[0].reference, "file-1")
        XCTAssertEqual(prefill.lines[0].filamentID, "pla-black")
        XCTAssertEqual(prefill.lines[0].quantity, 1)
        XCTAssertEqual(sampleOrderPrefill(fileID: "f", filamentID: "petg", defaultFilamentID: "pla", address: ada).lines[0].filamentID, "petg")
        XCTAssertEqual(sampleOrderPrefill(fileID: "f", filamentID: "", defaultFilamentID: nil, address: ada).lines[0].filamentID, "")

        // The composer seeds it like any prefilled address, and the draft goes through the normal payload.
        XCTAssertEqual(orderComposerDeliverySeed(prefill: prefill, lastDelivery: nil), .copiedFromOrder(deliveryDetails(fromSellerAddress: ada)))
        XCTAssertEqual(orderComposerInitialLines(prefill: prefill) { OrderLine() }.map(\.reference), ["file-1"])
        let delivery = try XCTUnwrap(prefill.delivery)
        let body = try orderDraftPayload(
            platformID: "plat", ownerID: "", email: delivery.email, recipientName: delivery.name, line1: delivery.line1,
            line2: delivery.line2, city: delivery.city, state: delivery.state, zip: delivery.zip,
            country: orderCountryPickerValue(delivery), paymentID: "", metadata: [:], options: [:], lines: prefill.lines
        )
        let address = ((body["customer"] as? [String: Any])?["details"] as? [String: Any])?["address"] as? [String: Any]
        XCTAssertEqual(address?["country"] as? String, "GB")
        XCTAssertEqual(address?["zip"] as? String, "SW1Y 4JH")
    }
}
