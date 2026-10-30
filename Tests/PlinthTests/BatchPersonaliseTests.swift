import XCTest
@testable import Plinth

final class BatchPersonaliseTests: XCTestCase {
    // MARK: Fixtures

    private let templatePath = "/tmp/BatchPersonaliseTests/keychain.scad"
    private let templateSource = """
    // Name on the keychain
    name = "Name"; // 12
    size = 40; // [20:80]
    module key() { cube(size); }
    key();
    """

    private func linkedProduct(sku: String = "KEY", quantity: Int = 1, valueName: String = "name") -> SavedProduct {
        var line = SavedProductLine()
        line.reference = "file-plain"
        line.filamentID = "filament-1"
        line.name = "Keychain"
        line.quantity = quantity
        line.template = SavedProductTemplateLink(templatePath: templatePath, valueName: valueName)
        var slip = SavedProductLine()
        slip.type = "STATIONERY"
        slip.reference = "slip-1"
        slip.perOrder = true
        return SavedProduct(name: "Keychain", sku: sku, lines: [line, slip])
    }

    private func plainProduct() -> SavedProduct {
        var line = SavedProductLine()
        line.reference = "file-tidy"
        line.filamentID = "filament-1"
        return SavedProduct(name: "Desk Tidy", sku: "TIDY", lines: [line])
    }

    private func order(_ items: [(sku: String, quantity: String, personalisation: String)]) -> OrderImportOrder {
        var order = OrderImportOrder(source: .etsy, sourceOrderID: "555")
        order.name = "Ana Lee"; order.email = "ana@example.com"; order.line1 = "1 Main St"; order.city = "Austin"
        order.state = "TX"; order.zip = "78701"; order.country = "US"; order.countryCode = "US"
        order.items = items.enumerated().map { index, entry in
            var item = OrderImportItem(sku: entry.sku, quantityText: entry.quantity, itemName: "Keychain", row: index + 2)
            item.personalisation = entry.personalisation
            return item
        }
        return order
    }

    private func context(_ products: [SavedProduct], choices: [String: OrderImportProductChoice] = [:]) -> OrderImportContext {
        OrderImportContext(products: products, platformID: "platform-1", productChoices: choices)
    }

    private func inputs(for products: [SavedProduct], openSCAD: Bool = true, choice: PersonalisationTextChoice? = .wholeText,
                        source: String? = nil) -> BatchPersonaliseInputs {
        let text = source ?? templateSource
        let file = PersonalisationTemplateFile(url: URL(fileURLWithPath: templatePath), source: text, template: scadTemplateParameters(text))
        var choices: [UUID: PersonalisationTextChoice] = [:]
        if let choice { for product in products where savedProductTemplateLine(product) != nil { choices[product.id] = choice } }
        return BatchPersonaliseInputs(openSCADAvailable: openSCAD, templates: [templatePath: .loaded(file)], choices: choices)
    }

    private func plan(_ eligibility: BatchPersonaliseEligibility, file: StaticString = #filePath, line: UInt = #line) -> BatchPersonalisePlan? {
        guard case .ready(let plan) = eligibility else { XCTFail("expected ready, got \(eligibility)", file: file, line: line); return nil }
        return plan
    }

    // MARK: Template link storage

    func testOldProductsFilesStillLoadAndLinksRoundTrip() throws {
        let old = #"[{"name":"Keychain","sku":"KEY","lines":[{"type":"PRINT","reference":"f1","filamentId":"x","quantity":1}]}]"#
        let decoded = try JSONDecoder().decode([SavedProduct].self, from: Data(old.utf8))
        XCTAssertEqual(decoded.count, 1)
        XCTAssertNil(decoded[0].lines[0].template)

        let product = linkedProduct()
        let data = try JSONEncoder().encode([product])
        let again = try JSONDecoder().decode([SavedProduct].self, from: data)
        XCTAssertEqual(again, [product])
        XCTAssertEqual(again[0].lines[0].template?.valueName, "name")
        let json = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(json.contains("Ana"), "no customer data")
    }

    func testDamagedLinkDropsOnlyTheLink() throws {
        let damaged = #"[{"name":"Keychain","lines":[{"type":"PRINT","reference":"f1","template":"oops"},{"type":"PRINT","reference":"f2","template":{"valueName":7}}]}]"#
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("BatchPersonaliseTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent(savedProductsFileName)
        try Data(damaged.utf8).write(to: url)
        let products = loadSavedProducts(from: url)
        XCTAssertEqual(products.count, 1)
        XCTAssertEqual(products[0].lines.map(\.reference), ["f1", "f2"])
        XCTAssertNil(products[0].lines[0].template)
        XCTAssertEqual(products[0].lines[1].template, SavedProductTemplateLink(templatePath: "", valueName: ""), "lenient fields")
        XCTAssertFalse(FileManager.default.fileExists(atPath: savedProductsBackupURL(for: url).path), "the file was readable")
    }

    func testLinkSaveChecksAndCleanUp() {
        var product = linkedProduct()
        XCTAssertNil(savedProductTemplateLinkProblem(product))
        XCTAssertNil(savedProductSaveBlockedReason(product, in: [], localModels: []))
        product.lines[0].template?.valueName = " "
        XCTAssertNotNil(savedProductSaveBlockedReason(product, in: [], localModels: []))
        product.lines[0].template = SavedProductTemplateLink(templatePath: "/tmp/model.stl", valueName: "name")
        XCTAssertNotNil(savedProductTemplateLinkProblem(product), "must be a .scad file")
        product = linkedProduct()
        product.lines[0].perOrder = true
        XCTAssertNotNil(savedProductTemplateLinkProblem(product))
        XCTAssertNil(savedProductTemplateLine(product))
        product = linkedProduct()
        product.lines.append(product.lines[0])
        XCTAssertEqual(savedProductTemplateLinkProblem(product), "Only one item of a product can be personalised from a template.")
        XCTAssertNil(savedProductTemplateLine(product))

        // Changing type clears the link; saving trims it and drops it from non-print items.
        let line = linkedProduct().lines[0]
        XCTAssertNil(savedProductLine(line, changingTypeTo: "COMPONENT").template)
        var spaced = linkedProduct()
        spaced.lines[0].template = SavedProductTemplateLink(templatePath: " \(templatePath) ", valueName: " name ")
        spaced.lines[1].template = SavedProductTemplateLink(templatePath: templatePath, valueName: "name")
        let saved = savedProductForSaving(spaced, localModels: [])
        XCTAssertEqual(saved.lines[0].template, SavedProductTemplateLink(templatePath: templatePath, valueName: "name"))
        XCTAssertNil(saved.lines[1].template)
        XCTAssertTrue(savedProductItemsSummary(saved, localModels: [], filaments: [], components: [], stationery: []).contains("personalised"))
        // Duplicating a product keeps its link.
        XCTAssertNotNil(savedProductTemplateLine(savedProductDuplicate(saved, in: [saved])))
    }

    // MARK: Personalisation text

    func testFieldSplitting() {
        XCTAssertEqual(personalisationFields("Sam"), [PersonalisationField(label: nil, value: "Sam")])
        XCTAssertEqual(personalisationFields("Sam, Alex"), [PersonalisationField(label: nil, value: "Sam, Alex")])
        XCTAssertEqual(personalisationFields("Name: Sam, Colour: Red"),
                       [PersonalisationField(label: "Name", value: "Sam"), PersonalisationField(label: "Colour", value: "Red")])
        XCTAssertEqual(personalisationFields("Name:Sam\r\nDate: 12:30\n\n"),
                       [PersonalisationField(label: "Name", value: "Sam"), PersonalisationField(label: "Date", value: "12:30")])
        XCTAssertEqual(personalisationFields("Happy birthday\nSam"),
                       [PersonalisationField(label: nil, value: "Happy birthday"), PersonalisationField(label: nil, value: "Sam")])
        XCTAssertEqual(personalisationFields("  "), [])
    }

    func testChoicesAreExplicitAndValuesExact() {
        XCTAssertEqual(personalisationTextChoices(["Sam", "Alex"]).map(\.choice), [.wholeText], "single values: whole text only")
        XCTAssertEqual(personalisationTextChoices(["Name: Sam, Colour: Red", "name: Alex"]).map(\.choice),
                       [.field("name"), .field("colour"), .wholeText])
        XCTAssertEqual(personalisationTextChoices(["Name: Sam"]).map(\.title), ["“Name” part", "Whole personalisation"])

        XCTAssertEqual(personalisationValue(" Sam ", choice: .wholeText), .value("Sam"))
        XCTAssertEqual(personalisationValue("Name: Sam, Colour: Red", choice: .field("name")), .value("Sam"))
        XCTAssertEqual(personalisationValue("NAME :  Sam", choice: .field("name")), .value("Sam"))
        guard case .problem = personalisationValue("Colour: Red", choice: .field("name")) else { return XCTFail("missing part") }
        guard case .problem = personalisationValue("Name: A\nName: B", choice: .field("name")) else { return XCTFail("ambiguous part") }
        guard case .problem = personalisationValue("Name: , Colour: Red", choice: .field("name")) else { return XCTFail("empty part") }
        guard case .problem = personalisationValue("Sam", choice: .field("name")) else { return XCTFail("no label is never guessed") }
    }

    // MARK: Eligibility

    func testEligibleOrderLosesThePlainWarningAndIsTicked() throws {
        let products = [linkedProduct()]
        let order = order([("KEY", "2", "Name: Sam, Colour: Red")])
        let check = orderImportCheck(order, context: context(products))
        XCTAssertTrue(check.warnings.contains(orderImportPlainModelWarning))
        XCTAssertEqual(check.itemProductIDs, [products[0].id])
        XCTAssertEqual(check.lineSources.map { $0?.savedLineID }, products[0].lines.map(\.id))

        let ready = batchPersonaliseEligibility(order, check: check, products: products, inputs: inputs(for: products, choice: .field("name")))
        let plan = try XCTUnwrap(plan(ready))
        XCTAssertEqual(plan.models.count, 1)
        XCTAssertEqual(plan.models[0].value, "Sam")
        XCTAssertEqual(plan.models[0].quantity, 2)
        XCTAssertEqual(plan.models[0].lineIndex, 0)
        XCTAssertEqual(plan.models[0].parameter.name, "name")
        let shown = batchPersonalisedCheck(check, eligibility: ready)
        XCTAssertFalse(shown.warnings.contains(orderImportPlainModelWarning))
        XCTAssertTrue(shown.tickedByDefault)
        XCTAssertTrue(shown.notes.contains { $0.contains("name = “Sam”") })
        XCTAssertEqual(batchPersonaliseNewlyTicked(before: [order.id: check], after: [order.id: shown]), [order.id])
        XCTAssertEqual(batchPersonaliseNewlyUnticked(before: [order.id: shown], after: [order.id: check]), [order.id])
        XCTAssertTrue(batchPersonaliseNewlyUnticked(before: [order.id: check], after: [order.id: shown]).isEmpty)
    }

    func testNothingIsPersonalisedWithoutOpenSCADOrAChoice() {
        let products = [linkedProduct()]
        let order = order([("KEY", "1", "Sam")])
        let check = orderImportCheck(order, context: context(products))
        XCTAssertEqual(batchPersonaliseEligibility(order, check: check, products: products, inputs: inputs(for: products, openSCAD: false)), .none)
        XCTAssertEqual(batchPersonaliseEligibility(order, check: check, products: products, inputs: inputs(for: products, choice: nil)), .none)
        let plain = order.items.map { item -> OrderImportItem in var item = item; item.personalisation = ""; return item }
        var unpersonalised = order; unpersonalised.items = plain
        XCTAssertEqual(batchPersonaliseEligibility(unpersonalised, check: orderImportCheck(unpersonalised, context: context(products)),
                                                   products: products, inputs: inputs(for: products)), .none)
        // A product without a template, alone, changes nothing.
        let tidy = [plainProduct()]
        let tidyOrder = self.order([("TIDY", "1", "Sam")])
        XCTAssertEqual(batchPersonaliseEligibility(tidyOrder, check: orderImportCheck(tidyOrder, context: context(tidy)),
                                                   products: tidy, inputs: inputs(for: tidy)), .none)
    }

    func testProblemsKeepThePlainModel() {
        let products = [linkedProduct()]
        func reasons(_ order: OrderImportOrder, _ inputs: BatchPersonaliseInputs, products all: [SavedProduct]) -> [String] {
            let check = orderImportCheck(order, context: context(all))
            guard case .unavailable(let problems) = batchPersonaliseEligibility(order, check: check, products: all, inputs: inputs) else { return [] }
            XCTAssertTrue(batchPersonalisedCheck(check, eligibility: .unavailable(problems)).warnings.contains(orderImportPlainModelWarning))
            return problems
        }
        // The chosen part is missing.
        XCTAssertFalse(reasons(order([("KEY", "1", "Colour: Red")]), inputs(for: products, choice: .field("name")), products: products).isEmpty)
        // Longer than the template's limit (12).
        XCTAssertFalse(reasons(order([("KEY", "1", "A very long name indeed")]), inputs(for: products), products: products).isEmpty)
        // Control characters.
        XCTAssertFalse(reasons(order([("KEY", "1", "Sam\u{7}")]), inputs(for: products), products: products).isEmpty)
        // The value isn't in the template, or isn't text.
        let missing = [linkedProduct(valueName: "label")]
        XCTAssertFalse(reasons(order([("KEY", "1", "Sam")]), inputs(for: missing), products: missing).isEmpty)
        let number = [linkedProduct(valueName: "size")]
        XCTAssertFalse(reasons(order([("KEY", "1", "Sam")]), inputs(for: number), products: number).isEmpty)
        // The template couldn't be read.
        var failed = inputs(for: products)
        failed.templates[templatePath] = .failed("gone")
        XCTAssertEqual(reasons(order([("KEY", "1", "Sam")]), failed, products: products), ["gone"])
        // Another personalised item's product has no template: the whole order stays plain.
        let mixed = products + [plainProduct()]
        XCTAssertFalse(reasons(order([("KEY", "1", "Sam"), ("TIDY", "1", "Alex")]), inputs(for: mixed), products: mixed).isEmpty)
    }

    func testItemsShareModelsOnlyForTheSameText() throws {
        let products = [linkedProduct(quantity: 2)]
        let order = order([("KEY", "1", "Sam"), ("KEY", "3", "Alex"), ("KEY", "1", "Sam"), ("KEY", "1", "")])
        let check = orderImportCheck(order, context: context(products))
        XCTAssertEqual(check.lines[0].quantity, 12, "6 units × 2 prints")
        let plan = try XCTUnwrap(plan(batchPersonaliseEligibility(order, check: check, products: products, inputs: inputs(for: products))))
        XCTAssertEqual(plan.models.map(\.value), ["Sam", "Alex"])
        XCTAssertEqual(plan.models.map(\.quantity), [4, 6])
        let lines = try XCTUnwrap(batchPersonaliseDraftLines(plan.baseLines, models: plan.models, fileIDs: ["f-sam", "f-alex"]))
        XCTAssertEqual(lines.map(\.reference), ["file-plain", "f-sam", "f-alex", "slip-1"])
        XCTAssertEqual(lines.map(\.quantity), [2, 4, 6, 1], "the unpersonalised unit keeps the plain model")
        XCTAssertEqual(lines.map(\.filamentID), ["filament-1", "filament-1", "filament-1", ""])
        XCTAssertEqual(Set(lines.map(\.sku)), ["KEY"])
    }

    func testLeftOutItemsAreIgnored() {
        var keyless = linkedProduct()
        keyless.sku = ""
        let products = [keyless]
        var order = order([("KEY", "1", "Sam")])
        order.items[0].sku = ""
        let key = orderImportMatchKey(for: order.items[0])!
        let leftOut = orderImportCheck(order, context: context(products, choices: [key.id: .leaveOut]))
        XCTAssertEqual(leftOut.itemProductIDs, [nil])
        XCTAssertEqual(batchPersonaliseEligibility(order, check: leftOut, products: products, inputs: inputs(for: products)), .none)
        let chosen = orderImportCheck(order, context: context(products, choices: [key.id: .product(keyless.id)]))
        XCTAssertEqual(chosen.itemProductIDs, [keyless.id], "Match products choices count")
        XCTAssertNotNil(plan(batchPersonaliseEligibility(order, check: chosen, products: products, inputs: inputs(for: products))))
    }

    func testBlockedOrdersAreNeverPersonalised() {
        let products = [linkedProduct()]
        var order = order([("KEY", "1", "Sam")])
        order.city = ""
        let check = orderImportCheck(order, context: context(products))
        XCTAssertFalse(check.canTick)
        XCTAssertEqual(batchPersonaliseEligibility(order, check: check, products: products, inputs: inputs(for: products)), .none)
    }

    func testSectionListsLinkedProductsOnce() {
        let products = [linkedProduct(), plainProduct()]
        let orders = [order([("KEY", "1", "Sam"), ("TIDY", "1", "x")]), order([("KEY", "1", "Alex")])]
        var second = orders[1]
        second = OrderImportOrder(source: .etsy, sourceOrderID: "556")
        second.items = orders[1].items
        let all = [orders[0], second]
        let checks = Dictionary(uniqueKeysWithValues: all.map { ($0.id, orderImportCheck($0, context: context(products))) })
        let entries = batchPersonaliseProducts(all, checks: checks, products: products)
        XCTAssertEqual(entries.map(\.product.name), ["Keychain"])
        XCTAssertEqual(entries.first?.texts, ["Sam", "Alex"])
    }

    // MARK: Drafting

    func testDraftLinesRefuseMismatches() throws {
        let products = [linkedProduct()]
        let order = order([("KEY", "1", "Sam")])
        let check = orderImportCheck(order, context: context(products))
        let plan = try XCTUnwrap(plan(batchPersonaliseEligibility(order, check: check, products: products, inputs: inputs(for: products))))
        XCTAssertNil(batchPersonaliseDraftLines(plan.baseLines, models: plan.models, fileIDs: []))
        XCTAssertNil(batchPersonaliseDraftLines(plan.baseLines, models: plan.models, fileIDs: [" "]))
        XCTAssertNil(batchPersonaliseDraftLines([], models: plan.models, fileIDs: ["f"]))
        var tooMany = plan.baseLines
        tooMany[0].quantity = 0
        XCTAssertNil(batchPersonaliseDraftLines(tooMany, models: plan.models, fileIDs: ["f"]))
        let lines = try XCTUnwrap(batchPersonaliseDraftLines(plan.baseLines, models: plan.models, fileIDs: ["f-sam"]))
        XCTAssertEqual(lines.map(\.reference), ["f-sam", "slip-1"], "a fully personalised line replaces the plain one")

        // The body goes through orderDraftPayload, with the same address, email, metadata and the new file.
        let body = try orderImportDraftBody(order, context: context(products), email: check.draftEmail, zip: check.draftZIP, lines: lines)
        let items = try XCTUnwrap(body["items"] as? [[String: Any]])
        XCTAssertEqual(items.first?["publicFileServiceId"] as? String, "f-sam")
        XCTAssertEqual((body["metadata"] as? [String: Any])?["sourceOrderId"] as? String, "555")
        let plain = try XCTUnwrap(check.body)
        XCTAssertEqual(prettyJSON(plain["customer"] as Any), prettyJSON(body["customer"] as Any))
        XCTAssertFalse(prettyJSON(body).contains("Sam"), "the buyer's text isn't sent in the draft")
    }

    func testUploadNamesNeverCarryBuyerText() {
        XCTAssertEqual(batchPersonaliseUploadName(source: .etsy, sourceOrderID: "3456789012", index: 0, count: 1), "Etsy order 3456789012 personalised")
        XCTAssertEqual(batchPersonaliseUploadName(source: .shopify, sourceOrderID: "#1001", index: 1, count: 2), "Shopify order #1001 personalised 2 of 2")
        XCTAssertEqual(batchPersonaliseUploadName(source: .shopify, sourceOrderID: "1001", index: 0, count: 1), "Shopify order 1001 personalised")
        // Studio's template takes any typed ID, so its uploads are always neutral.
        for id in ["T-1002", "1002", "#1002"] {
            XCTAssertEqual(batchPersonaliseUploadName(source: .template, sourceOrderID: id, index: 0, count: 1), "Personalised model", id)
        }
        // Letters (which could spell a name) never go into the name, whatever the source.
        for id in ["Sam-Smith", "Sam Smith 1", "Emma 2", "", "../1", String(repeating: "1", count: 21), "Zoë1", "EMMA12", "#SH1001", "12-34", "١٢٣"] {
            for source in OrderImportFormat.allCases {
                XCTAssertEqual(batchPersonaliseUploadName(source: source, sourceOrderID: id, index: 0, count: 1), "Personalised model", "\(source) \(id)")
            }
        }
        XCTAssertEqual(batchPersonaliseUploadName(source: .etsy, sourceOrderID: "#3456", index: 0, count: 1), "Personalised model",
                       "Etsy order numbers are digits only")
    }

    // MARK: Outcomes

    func testUploadOutcomes() {
        XCTAssertEqual(batchPersonaliseUploadOutcome(response: ["publicFileServiceId": "f1", "name": "x"]), .uploaded(fileID: "f1"))
        guard case .unknown = batchPersonaliseUploadOutcome(response: ["name": "Etsy order 1 personalised"]) else { return XCTFail("a name isn't an ID") }
        func http(_ status: Int) -> Error { APIError.http(status: status, body: "", retryAfter: nil, rateLimitReset: nil) }
        for status in [400, 401, 403, 404, 413, 422, 429] {
            guard case .refused = batchPersonaliseUploadOutcome(error: http(status)) else { return XCTFail("\(status) is a refusal") }
        }
        for error in [http(408), http(409), http(500), http(503), URLError(.timedOut), URLError(.networkConnectionLost),
                      APIError.invalidResponse("bad"), CancellationError()] as [Error] {
            guard case .unknown = batchPersonaliseUploadOutcome(error: error) else { return XCTFail("\(error) is unknown") }
        }
        guard case .refused = batchPersonaliseUploadOutcome(error: APIError.invalidRequest("before sending")) else { return XCTFail("not sent") }
    }

    func testOutcomeDecidesContinueOrStop() {
        XCTAssertEqual(batchPersonaliseNextStep(after: .ready(["f"]), consecutiveRefusals: 0), .next)
        guard case .stop = batchPersonaliseNextStep(after: .unknown("x"), consecutiveRefusals: 0) else { return XCTFail("unknown upload stops") }
        XCTAssertEqual(batchPersonaliseNextStep(after: .stopped("Stopped."), consecutiveRefusals: 0), .stop("Stopped."))
        XCTAssertEqual(batchPersonaliseNextStep(after: .notMade("bad"), consecutiveRefusals: 1), .next)
        guard case .stop = batchPersonaliseNextStep(after: .notMade("bad"), consecutiveRefusals: 5) else { return XCTFail("too many in a row") }
        XCTAssertEqual(batchPersonaliseNextStep(after: .refused("no", APIError.http(status: 422, body: "", retryAfter: nil, rateLimitReset: nil)),
                                                consecutiveRefusals: 1), .next)
        guard case .stop = batchPersonaliseNextStep(after: .refused("no", APIError.http(status: 401, body: "", retryAfter: nil, rateLimitReset: nil)),
                                                    consecutiveRefusals: 1) else { return XCTFail("a refused key stops") }
    }

    func testActivityAndConfirmationCopy() {
        var tally = OrderImportTally(created: 2)
        tally.modelsUploaded = 2; tally.notPersonalised = 1; tally.uploadsUnconfirmed = 1
        XCTAssertEqual(orderImportActivityDetail(tally),
                       "2 drafts created · 2 personalised models uploaded · 1 not personalised · 1 upload not confirmed")
        XCTAssertEqual(orderImportActivityDetail(OrderImportTally(created: 1)), "1 draft created")
        XCTAssertNil(batchPersonaliseConfirmText(0))
        XCTAssertTrue(batchPersonaliseConfirmText(2)?.hasPrefix(" 2 drafts use personalised models") == true)
    }

    // MARK: Checking generated models

    private func stl(_ triangles: [[SIMD3<Float>]]) -> Data {
        var text = "solid t\n"
        for triangle in triangles {
            text += "facet normal 0 0 0\nouter loop\n"
            for point in triangle { text += "vertex \(point.x) \(point.y) \(point.z)\n" }
            text += "endloop\nendfacet\n"
        }
        return Data((text + "endsolid t\n").utf8)
    }

    func testGeneratedModelsMustBeClosed() throws {
        let a = SIMD3<Float>(0, 0, 0), b = SIMD3<Float>(10, 0, 0), c = SIMD3<Float>(0, 10, 0), d = SIMD3<Float>(0, 0, 10)
        let closed = stl([[a, c, b], [a, b, d], [b, c, d], [c, a, d]])
        XCTAssertEqual(try STLMesh.parse(batchPersonaliseCheckedSTL(closed)).triangleCount, 4)
        XCTAssertThrowsError(try batchPersonaliseCheckedSTL(stl([[a, b, c]])), "an open surface isn't uploaded")
        XCTAssertThrowsError(try batchPersonaliseCheckedSTL(Data()))
        XCTAssertThrowsError(try batchPersonaliseCheckedSTL(Data("not an stl".utf8)))
    }

    func testTempFoldersUseTheCleanedUpPrefix() {
        XCTAssertTrue(isPersonalisationTempFolderName("\(personalisationTempFolderPrefixes[1])\(UUID().uuidString)"))
    }

    // MARK: Making models (local only: every case here stops before an upload)

    private func folder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("BatchPersonaliseRun-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return folder
    }

    /// A fake OpenSCAD that writes `stl` to its `-o` path (or fails when nil), recording each `-D` it was given.
    private func fakeOpenSCAD(in folder: URL, stl: Data?) throws -> URL {
        let model = folder.appendingPathComponent("fixture.stl")
        if let stl { try stl.write(to: model) }
        let argsFile = folder.appendingPathComponent("args.txt")
        let script = folder.appendingPathComponent("fake-openscad")
        let body = stl == nil ? "echo 'ERROR: broken template' >&2\nexit 1\n" : """
        out=""
        while [ $# -gt 0 ]; do
          if [ "$1" = "-o" ]; then out="$2"; shift; fi
          if [ "$1" = "-D" ]; then printf '%s\\n' "$2" >> '\(argsFile.path)'; shift; fi
          shift
        done
        cp '\(model.path)' "$out"
        """
        try ("#!/bin/sh\n" + body).write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return script
    }

    private func job(templateURL: URL, source: String, values: [String]) -> BatchPersonaliseJob {
        let parameter = scadTemplateParameters(source).parameters[0]
        let models = values.map { BatchPersonaliseModel(productID: UUID(), productName: "Keychain", lineIndex: 0, quantity: 1, value: $0,
                                                        parameter: parameter, templateURL: templateURL, templateSource: source) }
        var line = OrderLine(); line.reference = "plain"; line.filamentID = "f"; line.quantity = values.count
        return BatchPersonaliseJob(plan: BatchPersonalisePlan(models: models, baseLines: [line]),
                                   uploadNames: values.indices.map { _ in "Personalised model" }, makeBody: { _ in [:] })
    }

    private final class Calls { var uploads = 0; var paces = 0; var statuses: [String] = [] }

    @MainActor
    private func run(_ job: BatchPersonaliseJob, openSCAD: URL, calls: Calls, stop: @escaping () -> Bool = { false }) async -> BatchPersonaliseStepOutcome {
        await batchPersonaliseMakeAndUpload(job, client: APIClient(apiKey: ""), platformID: "platform-1", ownerID: "", hooks: BatchPersonaliseRunHooks(
            status: { calls.statuses.append($0) },
            pace: { calls.paces += 1; return "Stopped before uploading." },
            accountProblem: { nil },
            isStopRequested: stop,
            uploadSent: { _ in calls.uploads += 1 }), openSCAD: openSCAD)
    }

    private var closedSTL: Data {
        let a = SIMD3<Float>(0, 0, 0), b = SIMD3<Float>(10, 0, 0), c = SIMD3<Float>(0, 10, 0), d = SIMD3<Float>(0, 0, 10)
        return stl([[a, c, b], [a, b, d], [b, c, d], [c, a, d]])
    }

    @MainActor
    func testEveryModelIsMadeBeforeAnyUpload() async throws {
        let folder = try folder()
        let template = folder.appendingPathComponent("keychain.scad")
        try templateSource.write(to: template, atomically: true, encoding: .utf8)
        let fake = try fakeOpenSCAD(in: folder, stl: closedSTL)
        let calls = Calls()
        let outcome = await run(job(templateURL: template, source: templateSource, values: ["O'Neil \"$HOME\"", "Alex"]), openSCAD: fake, calls: calls)
        guard case .stopped("Stopped before uploading.") = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(calls.paces, 1, "paced once, after both models were made")
        XCTAssertEqual(calls.uploads, 0)
        let args = try String(contentsOf: folder.appendingPathComponent("args.txt"), encoding: .utf8)
        XCTAssertEqual(args, #"name="O'Neil \"$HOME\"""# + "\n" + #"name="Alex""# + "\n", "one escaped -D per model, nothing else set")
        XCTAssertEqual(calls.statuses.prefix(2), ["Making personalised model 1 of 2…", "Making personalised model 2 of 2…"])
    }

    @MainActor
    func testModelsThatCantBeMadeSkipTheOrderWithoutUploading() async throws {
        let folder = try folder()
        let template = folder.appendingPathComponent("keychain.scad")
        try templateSource.write(to: template, atomically: true, encoding: .utf8)
        let a = SIMD3<Float>(0, 0, 0), b = SIMD3<Float>(10, 0, 0), c = SIMD3<Float>(0, 10, 0)
        for (stl, label) in [(nil, "OpenSCAD fails"), (stl([[a, b, c]]), "open surface"), (Data("junk".utf8), "not an STL")] as [(Data?, String)] {
            let calls = Calls()
            let outcome = await run(job(templateURL: template, source: templateSource, values: ["Sam"]),
                                    openSCAD: try fakeOpenSCAD(in: try self.folder(), stl: stl), calls: calls)
            guard case .notMade = outcome else { XCTFail("\(label): \(outcome)"); continue }
            XCTAssertEqual(calls.paces + calls.uploads, 0, label)
        }
        // The template changed since it was reviewed.
        let calls = Calls()
        let changed = await run(job(templateURL: template, source: templateSource + "\n// edited", values: ["Sam"]),
                                openSCAD: try fakeOpenSCAD(in: folder, stl: closedSTL), calls: calls)
        guard case .notMade = changed else { return XCTFail("\(changed)") }
        XCTAssertEqual(calls.uploads, 0)
    }

    @MainActor
    func testStopEndsTheOrderBeforeMakingAModel() async throws {
        let folder = try folder()
        let template = folder.appendingPathComponent("keychain.scad")
        try templateSource.write(to: template, atomically: true, encoding: .utf8)
        let calls = Calls()
        let outcome = await run(job(templateURL: template, source: templateSource, values: ["Sam"]),
                                openSCAD: try fakeOpenSCAD(in: folder, stl: closedSTL), calls: calls, stop: { true })
        guard case .stopped = outcome else { return XCTFail("\(outcome)") }
        XCTAssertTrue(calls.statuses.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("args.txt").path), "OpenSCAD never ran")
    }
}
