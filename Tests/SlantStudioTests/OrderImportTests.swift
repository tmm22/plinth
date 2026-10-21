import XCTest
@testable import SlantStudio

final class OrderImportTests: XCTestCase {
    // MARK: Fixtures

    private func product(_ name: String, sku: String) -> SavedProduct {
        var line = SavedProductLine()
        line.reference = "file-\(sku)"
        line.filamentID = "filament-1"
        line.name = name
        return SavedProduct(name: name, sku: sku, lines: [line])
    }

    private var products: [SavedProduct] { [product("Desk Tidy", sku: "TIDY"), product("Cable Clip", sku: "clip-2")] }

    private func context(fallbackEmail: String = "", ledger: OrderImportLedger = OrderImportLedger(),
                         loadedKeys: Set<String> = []) -> OrderImportContext {
        OrderImportContext(products: products, platformID: "platform-1", fallbackEmail: fallbackEmail,
                           ledger: ledger, loadedKeys: loadedKeys)
    }

    private func parse(_ text: String) throws -> OrderImportParse {
        try orderImportParse(data: Data(text.utf8))
    }

    private let shopify = """
    Name,Email,Financial Status,Fulfillment Status,Lineitem quantity,Lineitem name,Lineitem sku,Shipping Name,Shipping Company,Shipping Address1,Shipping Address2,Shipping City,Shipping Zip,Shipping Province,Shipping Country,Cancelled at\r
    #1001,ana@example.com,paid,unfulfilled,2,Desk Tidy,TIDY,Ana Lee,,1 Main St,,Boston,'02134,MA,US,\r
    #1001,ana@example.com,,,1,Cable Clip,CLIP-2,,,,,,,,,\r
    #1002,ben@example.com,paid,fulfilled,1,Desk Tidy,TIDY,Ben Ng,,2 High St,,Leeds,LS1 1AA,,GB,\r
    """

    private let etsy = """
    Sale Date,Item Name,Buyer,Quantity,Price,Order ID,Date Shipped,Ship Name,Ship Address1,Ship Address2,Ship City,Ship State,Ship Zipcode,Ship Country,SKU
    10/01/26,Desk Tidy,ana,1,10.00,555,,Ana O&#39;Brien,1 Main St,,Austin,TX,78701,United States,TIDY
    10/01/26,Desk Tidy,ben,1,10.00,556,10/03/26,Ben Ng,2 High St,,Leeds,,LS1 1AA,United Kingdom,TIDY
    10/01/26,Cable Clip,ana,3,2.00,555,,Ana O&#39;Brien,1 Main St,,Austin,TX,78701,United States, clip-2
    """

    // MARK: Decoding

    func testDecodingStripsUTF8ByteOrderMark() throws {
        let data = Data([0xEF, 0xBB, 0xBF]) + Data("order_id,name\r\n".utf8)
        XCTAssertEqual(try orderImportDecodedText(data), "order_id,name\r\n")
    }

    func testDecodingFallsBackToWindows1252() throws {
        // "José" in Windows-1252: é is 0xE9, which isn't valid UTF-8 on its own.
        let data = Data([0x4A, 0x6F, 0x73, 0xE9])
        XCTAssertEqual(try orderImportDecodedText(data), "José")
    }

    func testDecodingReadsUTF16WithByteOrderMark() throws {
        var data = Data([0xFF, 0xFE])
        data.append("a,é".data(using: .utf16LittleEndian)!)
        XCTAssertEqual(try orderImportDecodedText(data), "a,é")
    }

    func testDecodingRefusesBinaryAndOversizedFiles() {
        XCTAssertThrowsError(try orderImportDecodedText(Data([0x61, 0x00, 0x62])))
        XCTAssertThrowsError(try orderImportDecodedText(Data(repeating: 0x61, count: 11), maxBytes: 10))
        XCTAssertNoThrow(try orderImportDecodedText(Data(repeating: 0x61, count: 10), maxBytes: 10))
    }

    // MARK: CSV reader

    func testReaderHandlesQuotesEmbeddedLineBreaksAndCRLF() throws {
        let text = "a,b,c\r\n\"x, y\",\"say \"\"hi\"\"\",\"line one\r\nline two\"\r\n1,2,3"
        let csv = try parseOrderImportCSV(text)
        XCTAssertEqual(csv.header, ["a", "b", "c"])
        XCTAssertEqual(csv.rows, [["x, y", "say \"hi\"", "line one\r\nline two"], ["1", "2", "3"]])
        XCTAssertEqual(csv.rowNumbers, [2, 3])
    }

    func testReaderDetectsSemicolonsAndTrimsHeaders() throws {
        let csv = try parseOrderImportCSV(" order_id ; name ;city\n1;\"A; B\";Paris\n")
        XCTAssertEqual(csv.header, ["order_id", "name", "city"])
        XCTAssertEqual(csv.rows, [["1", "A; B", "Paris"]])
    }

    func testReaderSkipsBlankLinesButKeepsSpreadsheetRowNumbers() throws {
        let csv = try parseOrderImportCSV("a,b\n\n1,2\n\n3,4\n")
        XCTAssertEqual(csv.rows, [["1", "2"], ["3", "4"]])
        XCTAssertEqual(csv.rowNumbers, [3, 5])
    }

    func testReaderKeepsTrailingEmptyCells() throws {
        let csv = try parseOrderImportCSV("a,b,c\n1,,\n")
        XCTAssertEqual(csv.rows, [["1", "", ""]])
    }

    func testReaderRefusesUnclosedQuotesAndOverCapFiles() {
        XCTAssertThrowsError(try parseOrderImportCSV("a,b\n\"never closed,2\n3,4\n"))
        XCTAssertThrowsError(try parseOrderImportCSV("a\n1\n2\n3\n", maxRows: 2))
        XCTAssertNoThrow(try parseOrderImportCSV("a\n1\n2\n", maxRows: 2))
        XCTAssertThrowsError(try parseOrderImportCSV("a\n" + String(repeating: "x", count: 51), maxCellLength: 50))
        XCTAssertThrowsError(try parseOrderImportCSV(""))
    }

    func testFormulaLikeCellsAreReadAsPlainText() throws {
        let csv = try parseOrderImportCSV("a,b\n=HYPERLINK(\"http://x\"),+1\n")
        XCTAssertEqual(csv.rows, [["=HYPERLINK(\"http://x\")", "+1"]])
    }

    // MARK: Format detection

    func testDetectsEachFormatIgnoringCaseAndSpacing() throws {
        XCTAssertEqual(try parse(shopify).format, .shopify)
        XCTAssertEqual(try parse(etsy).format, .etsy)
        XCTAssertEqual(try parse(orderImportTemplateCSV()).format, .template)
        let layout = try orderImportLayout(header: ["ORDER_ID", "Name", "LINE1", "City", "Postcode", "Country", "SKU", "Qty"])
        XCTAssertEqual(layout.format, .template)
        XCTAssertEqual(layout.columns[.zip], 4)
        XCTAssertNil(layout.columns[.email])
    }

    func testEtsySoldOrdersFileWithoutSKUsExplainsWhichFileToUse() {
        XCTAssertThrowsError(try orderImportLayout(header: ["Order ID", "Ship Name", "Ship Address1", "Ship City", "Ship Zipcode", "Ship Country", "Quantity"])) { error in
            XCTAssertTrue(error.localizedDescription.contains("SKU"))
            XCTAssertTrue(error.localizedDescription.contains("Sold Order Items"))
        }
    }

    func testUnrecognisedHeadersListTheTemplateColumns() {
        XCTAssertThrowsError(try orderImportLayout(header: ["foo", "bar"])) { error in
            XCTAssertTrue(error.localizedDescription.contains("order_id, name, email, line1"))
        }
    }

    // MARK: Grouping

    func testShopifyExtraLineItemRowsInheritOrderFields() throws {
        let result = try parse(shopify)
        XCTAssertEqual(result.orders.map(\.sourceOrderID), ["#1001", "#1002"])
        let first = result.orders[0]
        XCTAssertEqual(first.items.map(\.sku), ["TIDY", "CLIP-2"])
        XCTAssertEqual(first.name, "Ana Lee")
        XCTAssertEqual(first.zip, "02134", "Shopify's leading apostrophe is removed")
        XCTAssertEqual(first.countryCode, "US")
        XCTAssertTrue(first.conflictingFields.isEmpty)
        XCTAssertNil(first.alreadyHandled)
        XCTAssertEqual(result.orders[1].alreadyHandled, "Shopify shows this order as fulfilled.")
    }

    func testEtsyRowsAreGroupedByOrderIDEvenWhenApart() throws {
        let result = try parse(etsy)
        XCTAssertEqual(result.orders.map(\.sourceOrderID), ["555", "556"])
        XCTAssertEqual(result.orders[0].items.map(\.quantityText), ["1", "3"])
        XCTAssertEqual(result.orders[0].rows, [2, 4])
        XCTAssertEqual(result.orders[0].name, "Ana O'Brien")
        XCTAssertTrue(result.orders[0].decodedEntities)
        XCTAssertEqual(result.orders[0].countryCode, "US")
        XCTAssertEqual(result.orders[1].countryCode, "GB")
        XCTAssertEqual(result.orders[1].alreadyHandled, "Etsy shows this order as shipped.")
    }

    func testRowsOfOneOrderWithDifferentAddressesAreAConflict() throws {
        let text = """
        order_id,name,email,line1,city,zip,country,sku,quantity
        7,Ana,a@example.com,1 Main St,Austin,78701,US,TIDY,1
        7,Ana,a@example.com,9 Other Rd,Austin,78701,US,TIDY,1
        """
        let order = try parse(text).orders[0]
        XCTAssertEqual(order.conflictingFields, ["address line 1"])
        let check = orderImportCheck(order, context: context())
        XCTAssertFalse(check.canTick)
        XCTAssertNil(check.body)
    }

    func testExactlyRepeatedRowsBlockInsteadOfDoublingItems() throws {
        let text = """
        order_id,name,email,line1,city,state,zip,country,sku,quantity
        7,Ana,a@example.com,1 Main St,Austin,TX,78701,US,TIDY,1
        7,Ana,a@example.com,1 Main St,Austin,TX,78701,US,clip-2,1
        7,Ana,a@example.com,1 Main St,Austin,TX,78701,US,TIDY,1
        """
        let order = try parse(text).orders[0]
        XCTAssertEqual(order.repeatedRows, [4])
        let check = orderImportCheck(order, context: context())
        XCTAssertEqual(check.blockers, ["Row 4 repeats an earlier row of this order exactly. Check the file wasn’t combined from overlapping exports."])
        XCTAssertNil(check.body)
    }

    func testColumnCapIsEnforced() {
        XCTAssertThrowsError(try parseOrderImportCSV("a,b,c\n1,2,3\n", maxColumns: 2))
        XCTAssertNoThrow(try parseOrderImportCSV("a,b\n1,2\n", maxColumns: 2))
    }

    func testRowsWithoutAnOrderIDAreReportedNotGuessed() throws {
        let text = "order_id,name,line1,city,zip,country,sku,quantity\n,Ana,1 Main,Austin,78701,US,TIDY,1\n8,Ben,2 Main,Austin,78701,US,TIDY,1\n"
        let result = try parse(text)
        XCTAssertEqual(result.orders.count, 1)
        XCTAssertEqual(result.notices, ["1 row without an order ID was ignored."])
    }

    func testOrderCapIsEnforced() throws {
        var lines = ["order_id,name,line1,city,zip,country,sku,quantity"]
        for index in 1...4 { lines.append("\(index),A,1 Main,Austin,78701,US,TIDY,1") }
        let csv = try parseOrderImportCSV(lines.joined(separator: "\n"))
        let layout = try orderImportLayout(header: csv.header)
        XCTAssertThrowsError(try orderImportOrders(from: csv, layout: layout, maxOrders: 3))
        XCTAssertEqual(try orderImportOrders(from: csv, layout: layout, maxOrders: 4).orders.count, 4)
    }

    func testShopifySkipRules() {
        XCTAssertEqual(orderImportAlreadyHandledReason(format: .shopify, dateShipped: "", fulfillmentStatus: "", cancelledAt: "2026-10-01", financialStatus: "paid"),
                       "Shopify shows this order as cancelled.")
        XCTAssertEqual(orderImportAlreadyHandledReason(format: .shopify, dateShipped: "", fulfillmentStatus: "", cancelledAt: "", financialStatus: "Refunded"),
                       "Shopify shows this order as refunded.")
        XCTAssertNotNil(orderImportAlreadyHandledReason(format: .shopify, dateShipped: "", fulfillmentStatus: "", cancelledAt: "", financialStatus: "voided"))
        XCTAssertNil(orderImportAlreadyHandledReason(format: .shopify, dateShipped: "", fulfillmentStatus: "unfulfilled", cancelledAt: "", financialStatus: "partially_refunded"))
        XCTAssertNil(orderImportAlreadyHandledReason(format: .template, dateShipped: "x", fulfillmentStatus: "fulfilled", cancelledAt: "x", financialStatus: "refunded"))
    }

    // MARK: Checks

    func testReadyOrderBuildsDraftBodyWithSourceMetadata() throws {
        let order = try parse(shopify).orders[0]
        let check = orderImportCheck(order, context: context())
        XCTAssertEqual(check.blockers, [])
        XCTAssertEqual(check.warnings, [])
        XCTAssertTrue(check.tickedByDefault)
        let body = try XCTUnwrap(check.body)
        XCTAssertEqual(body["platformId"] as? String, "platform-1")
        let metadata = try XCTUnwrap(body["metadata"] as? [String: Any])
        XCTAssertEqual(metadata as? [String: String], ["source": "shopify", "sourceOrderId": "#1001"])
        let items = try XCTUnwrap(body["items"] as? [[String: Any]])
        XCTAssertEqual(items.map { $0["quantity"] as? Int }, [2, 1])
        XCTAssertEqual(items.map { $0["publicFileServiceId"] as? String }, ["file-TIDY", "file-clip-2"])
        let details = try XCTUnwrap((body["customer"] as? [String: Any])?["details"] as? [String: Any])
        XCTAssertEqual(details["email"] as? String, "ana@example.com")
        XCTAssertEqual((details["address"] as? [String: Any])?["zip"] as? String, "02134")
        XCTAssertNil(body["options"])
        XCTAssertEqual(check.itemsSummary, "2 × Desk Tidy, 1 × Cable Clip")
    }

    func testSKUMatchingIgnoresCaseAndSurroundingSpaces() throws {
        let order = try parse(etsy).orders[0]
        XCTAssertEqual(order.items.map(\.sku), ["TIDY", "clip-2"])
        var upper = order
        upper.items = [OrderImportItem(sku: "  Clip-2 ", quantityText: "1", itemName: "", row: 2)]
        XCTAssertTrue(orderImportCheck(upper, context: context(fallbackEmail: "shop@example.com")).blockers.isEmpty)
    }

    func testUnknownSKUAndBadQuantitiesBlock() throws {
        var order = try parse(shopify).orders[0]
        order.items = [OrderImportItem(sku: "NOPE", quantityText: "1", itemName: "", row: 2)]
        XCTAssertEqual(orderImportCheck(order, context: context()).blockers, ["No saved product has SKU NOPE. Choose one under Match products, or add it in Saved Products."])
        for quantity in ["0", "1.5", "-1", "abc", "", "10001"] {
            order.items = [OrderImportItem(sku: "TIDY", quantityText: quantity, itemName: "", row: 2)]
            let check = orderImportCheck(order, context: context())
            XCTAssertFalse(check.canTick, "quantity \(quantity)")
            XCTAssertNil(check.body)
        }
        order.items = [OrderImportItem(sku: "", quantityText: "1", itemName: "Shipping protection", row: 3)]
        XCTAssertTrue(orderImportCheck(order, context: context()).blockers[0].contains("“Shipping protection” has no SKU"))
    }

    func testSavedProductBlockersCarryThrough() throws {
        var order = try parse(shopify).orders[0]
        order.items = [OrderImportItem(sku: "EMPTY", quantityText: "1", itemName: "", row: 2)]
        var ctx = context()
        ctx.products.append(SavedProduct(name: "Empty", sku: "EMPTY", lines: []))
        XCTAssertEqual(orderImportCheck(order, context: ctx).blockers, ["“Empty” has no items."])
    }

    func testMissingEmailNeedsTheFallbackFieldAndNeverInventsOne() throws {
        let order = try parse(etsy).orders[0]
        let waiting = orderImportCheck(order, context: context())
        XCTAssertEqual(waiting.blockers, [orderImportMissingEmailBlocker])
        XCTAssertTrue(waiting.waitingForEmail)
        XCTAssertTrue(waiting.tickedByDefault, "ticked once the email is filled in")
        XCTAssertFalse(waiting.canTick)
        XCTAssertNil(waiting.body)
        XCTAssertNil(orderImportCheck(order, context: context(fallbackEmail: "not an email")).body)
        let filled = orderImportCheck(order, context: context(fallbackEmail: " shop@example.com "))
        XCTAssertTrue(filled.usesFallbackEmail)
        let details = (filled.body?["customer"] as? [String: Any])?["details"] as? [String: Any]
        XCTAssertEqual(details?["email"] as? String, "shop@example.com")
    }

    func testInvalidOrderEmailIsNotReplacedByTheFallback() throws {
        var order = try parse(shopify).orders[0]
        order.email = "ana@"
        let check = orderImportCheck(order, context: context(fallbackEmail: "shop@example.com"))
        XCTAssertEqual(check.blockers, ["Email “ana@” isn’t a valid address."])
        XCTAssertFalse(check.waitingForEmail)
    }

    func testCountryAndStateProblems() throws {
        var order = try parse(shopify).orders[0]
        XCTAssertEqual(orderImportCountryCode("United States"), "US")
        XCTAssertEqual(orderImportCountryCode("usa"), "US")
        XCTAssertEqual(orderImportCountryCode("UK"), "GB")
        XCTAssertEqual(orderImportCountryCode("de"), "DE")
        XCTAssertEqual(orderImportCountryCode("Narnia"), "")
        XCTAssertEqual(orderImportCountryCode("EU"), "")
        XCTAssertEqual(orderImportCountryCode(""), "")
        order.country = "Narnia"; order.countryCode = ""
        XCTAssertTrue(orderImportCheck(order, context: context()).blockers.contains { $0.contains("Narnia") })
        order.country = ""
        XCTAssertTrue(orderImportCheck(order, context: context()).blockers.contains("Missing country."))
        order.country = "US"; order.countryCode = "US"; order.state = ""
        XCTAssertTrue(orderImportCheck(order, context: context()).blockers.contains("A state or province is required for US."))
    }

    func testShortUSZIPWarnsAndOnlyPadsWhenChosen() throws {
        var order = try parse(shopify).orders[0]
        order.zip = "2134"
        let warned = orderImportCheck(order, context: context())
        XCTAssertEqual(warned.paddedZIP, "02134")
        XCTAssertFalse(warned.tickedByDefault)
        XCTAssertTrue(warned.canTick)
        let unpadded = (warned.body?["customer"] as? [String: Any])?["details"] as? [String: Any]
        XCTAssertEqual((unpadded?["address"] as? [String: Any])?["zip"] as? String, "2134", "never padded automatically")
        let padded = orderImportCheck(order, context: context(), padZIP: true)
        XCTAssertTrue(padded.warnings.isEmpty)
        let details = (padded.body?["customer"] as? [String: Any])?["details"] as? [String: Any]
        XCTAssertEqual((details?["address"] as? [String: Any])?["zip"] as? String, "02134")
        XCTAssertEqual(orderImportPaddedUSZIP("601-1234"), "00601-1234")
        XCTAssertNil(orderImportPaddedUSZIP("12"))
        XCTAssertNil(orderImportPaddedUSZIP("02134"))
        XCTAssertNil(orderImportPaddedUSZIP("ABCD"))
    }

    func testCompanyAndAlreadyShippedNeedAnExplicitTick() throws {
        var order = try parse(shopify).orders[0]
        order.company = "Acme Ltd"
        let company = orderImportCheck(order, context: context())
        XCTAssertTrue(company.canTick)
        XCTAssertFalse(company.tickedByDefault)
        XCTAssertNotNil(company.body)
        let shipped = orderImportCheck(try parse(shopify).orders[1], context: context())
        XCTAssertTrue(shipped.canTick)
        XCTAssertFalse(shipped.tickedByDefault)
    }

    func testOverlongDeliveryFieldsBlock() throws {
        var order = try parse(shopify).orders[0]
        order.line1 = String(repeating: "x", count: orderImportMaxFieldLength + 1)
        let check = orderImportCheck(order, context: context())
        XCTAssertEqual(check.blockers, ["The address line 1 is longer than \(orderImportMaxFieldLength) characters."])
        XCTAssertNil(check.body)
    }

    func testHTMLEntityDecoding() {
        XCTAssertEqual(orderImportDecodingHTMLEntities("O&#39;Brien &amp; Sons &quot;HQ&quot; &#x41;"), "O'Brien & Sons \"HQ\" A")
        XCTAssertEqual(orderImportDecodingHTMLEntities("Tom & Jerry &unknown; &#0; &#x1b;"), "Tom & Jerry &unknown; &#0; &#x1b;")
        XCTAssertEqual(orderImportDecodingHTMLEntities("&amp;#39;"), "&#39;", "decoded once only")
    }

    // MARK: Duplicates

    func testLedgerAndLoadedMetadataFlagDuplicates() throws {
        let order = try parse(shopify).orders[0]
        var ledger = OrderImportLedger()
        ledger.record(.created(orderID: "ORD-1"), source: .shopify, sourceOrderID: "#1001")
        let created = orderImportCheck(order, context: context(ledger: ledger))
        XCTAssertEqual(created.warnings, ["Already imported this session as draft ORD-1."])
        XCTAssertFalse(created.tickedByDefault)
        XCTAssertTrue(created.canTick)

        ledger.record(.unknown, source: .shopify, sourceOrderID: "#1001")
        XCTAssertTrue(orderImportCheck(order, context: context(ledger: ledger)).warnings[0].contains("may have been created"))

        // The same ID from a different marketplace isn't a duplicate.
        var etsyLedger = OrderImportLedger()
        etsyLedger.record(.created(orderID: "ORD-2"), source: .etsy, sourceOrderID: "#1001")
        XCTAssertTrue(orderImportCheck(order, context: context(ledger: etsyLedger)).warnings.isEmpty)

        let loaded = [
            Record(values: ["publicId": "A", "metadata": ["source": "shopify", "sourceOrderId": "#1001"]]),
            Record(values: ["publicId": "B", "metadata": ["sourceOrderId": "556"]]),
            Record(values: ["publicId": "C"]),
            Record(values: ["order": ["publicId": "D", "metadata": ["source": "etsy", "sourceOrderId": 777]]])
        ]
        let keys = orderImportLoadedSourceKeys(loaded)
        XCTAssertTrue(keys.contains("shopify|#1001"))
        XCTAssertTrue(keys.contains("etsy|556"), "metadata without a source matches any source")
        XCTAssertTrue(keys.contains("etsy|777"))
        XCTAssertFalse(keys.contains("etsy|#1001"))
        XCTAssertFalse(orderImportCheck(order, context: context(loadedKeys: keys)).tickedByDefault)
    }

    func testCoverageNotice() {
        XCTAssertNotNil(orderImportDuplicateCoverageNotice(ordersLoaded: false, ordersHasMore: false, listIsPartial: false))
        XCTAssertNotNil(orderImportDuplicateCoverageNotice(ordersLoaded: true, ordersHasMore: true, listIsPartial: false))
        XCTAssertNotNil(orderImportDuplicateCoverageNotice(ordersLoaded: true, ordersHasMore: false, listIsPartial: true))
        XCTAssertNil(orderImportDuplicateCoverageNotice(ordersLoaded: true, ordersHasMore: false, listIsPartial: false))
    }

    // MARK: Runner decisions

    private func http(_ status: Int, reset: String? = nil) -> APIError {
        .http(status: status, body: "", retryAfter: nil, rateLimitReset: reset)
    }

    func testSuccessfulReplyIsCreatedOnlyWithAnOrderNumber() {
        XCTAssertEqual(orderImportOutcome(response: ["order": ["publicId": "ORD-9", "status": "DRAFT"], "items": []]), .created(orderID: "ORD-9"))
        guard case .unknown = orderImportOutcome(response: ["items": []]) else { return XCTFail("missing order number must be unknown") }
    }

    func testErrorsAreRefusedOnlyWhenTheyProveNoEffect() {
        for status in [400, 401, 403, 404, 422, 429] {
            guard case .refused = orderImportOutcome(error: http(status)) else { return XCTFail("\(status) should be refused") }
        }
        guard case .refused = orderImportOutcome(error: APIError.invalidRequest("bad")) else { return XCTFail() }
        for status in [408, 409, 500, 502, 503] {
            guard case .unknown = orderImportOutcome(error: http(status)) else { return XCTFail("\(status) should be unknown") }
        }
        for error: Error in [URLError(.timedOut), URLError(.networkConnectionLost), URLError(.cancelled),
                             APIError.invalidResponse("x"), CancellationError()] {
            guard case .unknown = orderImportOutcome(error: error) else { return XCTFail("\(error) should be unknown") }
        }
        XCTAssertEqual(orderImportOutcome(error: http(429)), .refused("Slant’s rate limit was reached, so this draft wasn’t created."))
    }

    func testUnknownOutcomeStopsTheBatchAndRefusalsContinue() {
        XCTAssertEqual(orderImportNextStep(after: .created(orderID: "A"), error: nil, consecutiveRefusals: 0), .next)
        guard case .stop = orderImportNextStep(after: .unknown("x"), error: http(500), consecutiveRefusals: 0) else { return XCTFail() }
        XCTAssertEqual(orderImportNextStep(after: .refused("x"), error: http(422), consecutiveRefusals: 1), .next)
        XCTAssertEqual(orderImportNextStep(after: .refused("x"), error: http(429), consecutiveRefusals: 1), .next)
        guard case .stop = orderImportNextStep(after: .refused("x"), error: http(401), consecutiveRefusals: 1) else { return XCTFail() }
        guard case .stop = orderImportNextStep(after: .refused("x"), error: http(403), consecutiveRefusals: 1) else { return XCTFail() }
        guard case .stop = orderImportNextStep(after: .refused("x"), error: http(400), consecutiveRefusals: 5, maxConsecutiveRefusals: 5) else { return XCTFail() }
    }

    func testPacingSpacesRequestsAndWaitsForRateLimitResets() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertEqual(orderImportPacing(lastRequestStart: nil, rateLimit: nil, rateLimitedUntil: nil, now: now), .wait(0))
        XCTAssertEqual(orderImportPacing(lastRequestStart: now.addingTimeInterval(-0.25), rateLimit: nil, rateLimitedUntil: nil, now: now,
                                         minimumSpacing: 1), .wait(0.75))
        XCTAssertEqual(orderImportPacing(lastRequestStart: now.addingTimeInterval(-5), rateLimit: nil, rateLimitedUntil: now.addingTimeInterval(30), now: now), .wait(30))
        let low = RateLimitInfo(limit: 100, remaining: 3, reset: now.addingTimeInterval(40), role: nil)
        XCTAssertEqual(orderImportPacing(lastRequestStart: nil, rateLimit: low, rateLimitedUntil: nil, now: now), .wait(40))
        let plenty = RateLimitInfo(limit: 100, remaining: 80, reset: now.addingTimeInterval(40), role: nil)
        XCTAssertEqual(orderImportPacing(lastRequestStart: nil, rateLimit: plenty, rateLimitedUntil: nil, now: now), .wait(0))
        let pastReset = RateLimitInfo(limit: 100, remaining: 0, reset: now.addingTimeInterval(-1), role: nil)
        XCTAssertEqual(orderImportPacing(lastRequestStart: nil, rateLimit: pastReset, rateLimitedUntil: nil, now: now), .wait(0))
        guard case .stop = orderImportPacing(lastRequestStart: nil, rateLimit: nil, rateLimitedUntil: now.addingTimeInterval(3600), now: now) else {
            return XCTFail("an hour-long wait should stop the batch")
        }
    }

    func testActivityDetailHoldsCountsOnly() {
        XCTAssertEqual(orderImportActivityDetail(OrderImportTally(created: 1)), "1 draft created")
        XCTAssertEqual(orderImportActivityDetail(OrderImportTally(created: 3, refused: 1, unknown: 1, notSent: 2)),
                       "3 drafts created · 1 refused · 1 not confirmed · 2 not sent")
    }

    // MARK: Template

    func testTemplateRoundTripsAsOneOrder() throws {
        let result = try parse(orderImportTemplateCSV())
        XCTAssertEqual(result.format, .template)
        XCTAssertEqual(result.orders.count, 1)
        let order = result.orders[0]
        XCTAssertEqual(order.email, "alex@example.com")
        XCTAssertEqual(order.countryCode, "US")
        XCTAssertEqual(order.items, [OrderImportItem(sku: "YOUR-SKU", quantityText: "1", itemName: "", row: 2)])
        XCTAssertEqual(orderImportMetadata(source: .template, sourceOrderID: " 1001 ") as? [String: String],
                       ["source": "csv", "sourceOrderId": "1001"])
    }

    // MARK: Delimiters and Excel's sep= line

    func testDelimiterDetectionSkipsLeadingBlankLines() throws {
        let csv = try parseOrderImportCSV("\n  \r\norder_id;name;note\n1;\"A; B\";x,y\n")
        XCTAssertEqual(csv.header, ["order_id", "name", "note"])
        XCTAssertEqual(csv.rows, [["1", "A; B", "x,y"]])
        XCTAssertEqual(csv.rowNumbers, [4])
        XCTAssertEqual(orderImportDelimiter(Array("\n\na\tb\tc\n1,2,3,4,5\n".unicodeScalars)), "\t")
    }

    func testExcelSepLineSetsTheDelimiterAndIsDropped() throws {
        let semicolon = try parseOrderImportCSV("sep=;\r\norder_id;name,x\r\n1;A,B\r\n")
        XCTAssertEqual(semicolon.header, ["order_id", "name,x"])
        XCTAssertEqual(semicolon.rows, [["1", "A,B"]])
        XCTAssertEqual(semicolon.rowNumbers, [2], "Excel hides the sep= line, so the header stays row 1")
        let quotedTab = try parseOrderImportCSV("\"SEP=\t\"\na,b\tc\n1,2\t3\n")
        XCTAssertEqual(quotedTab.header, ["a,b", "c"])
        XCTAssertEqual(quotedTab.rows, [["1,2", "3"]])
        // A header that merely starts with "sep" is data, not a delimiter line.
        let header = try parseOrderImportCSV("separator,b\n1,2\n")
        XCTAssertEqual(header.header, ["separator", "b"])
        XCTAssertEqual(orderImportSeparatorLine(Array("sep=;;\n".unicodeScalars))?.delimiter, nil)
        XCTAssertEqual(try parse("sep=;\n" + orderImportTemplateCSV().replacingOccurrences(of: ",", with: ";")).orders.count, 1)
    }

    func testRowsOfOnlyEmptyCellsAreSkipped() throws {
        let csv = try parseOrderImportCSV(",,\na,b\n, ,\n1,2\n")
        XCTAssertEqual(csv.header, ["a", "b"])
        XCTAssertEqual(csv.rows, [["1", "2"]])
        XCTAssertEqual(csv.rowNumbers, [4])
    }

    // MARK: Repeated rows

    func testIdenticalShopifyFollowOnRowsAreNotRepeats() throws {
        let text = """
        Name,Email,Lineitem quantity,Lineitem name,Lineitem sku,Shipping Name,Shipping Address1,Shipping City,Shipping Zip,Shipping Province,Shipping Country
        #1,ana@example.com,1,Desk Tidy,TIDY,Ana Lee,1 Main St,Boston,02134,MA,US
        #1,,1,Cable Clip,CLIP-2,,,,,,
        #1,,1,Cable Clip,CLIP-2,,,,,,
        #1,ana@example.com,1,Cable Clip,CLIP-2,,,,,,
        #1,ana@example.com,1,Cable Clip,CLIP-2,,,,,,
        """
        var order = try parse(text).orders[0]
        XCTAssertEqual(order.repeatedRows, [], "follow-on rows, even ones repeating the email, aren't overlapping exports")
        XCTAssertEqual(order.items.count, 5)
        order.items.removeLast(2)
        let check = orderImportCheck(order, context: context())
        XCTAssertEqual(check.blockers, [])
        XCTAssertEqual(check.lines.map(\.quantity), [1, 2], "the same SKU on two rows is one line with the units summed")
        XCTAssertEqual(check.itemsSummary, "1 × Desk Tidy, 2 × Cable Clip")
    }

    func testOverlappingShopifyExportsStillBlock() throws {
        let text = """
        Name,Email,Lineitem quantity,Lineitem name,Lineitem sku,Shipping Name,Shipping Address1,Shipping City,Shipping Zip,Shipping Province,Shipping Country
        #1,ana@example.com,1,Desk Tidy,TIDY,Ana Lee,1 Main St,Boston,02134,MA,US
        #1,,1,Cable Clip,CLIP-2,,,,,,
        #1,ana@example.com,1,Desk Tidy,TIDY,Ana Lee,1 Main St,Boston,02134,MA,US
        #1,,1,Cable Clip,CLIP-2,,,,,,
        """
        let order = try parse(text).orders[0]
        XCTAssertEqual(order.repeatedRows, [4])
        XCTAssertFalse(orderImportCheck(order, context: context()).canTick)
    }

    // MARK: Units per product and once-per-order lines

    private func slipLine(_ reference: String = "slip-1") -> SavedProductLine {
        SavedProductLine(type: "STATIONERY", reference: reference, quantity: 1, perOrder: true, name: "Packing slip")
    }

    private func order(_ items: [(sku: String, quantity: String)], name: [String] = []) throws -> OrderImportOrder {
        var order = try parse(shopify).orders[0]
        order.items = items.enumerated().map { index, item in
            OrderImportItem(sku: item.sku, quantityText: item.quantity, itemName: index < name.count ? name[index] : "", row: index + 2)
        }
        return order
    }

    func testTwoRowsOfTheSameSKUResolveOnceWithOneSlip() throws {
        var tidy = product("Desk Tidy", sku: "TIDY")
        tidy.lines.append(slipLine())
        var ctx = context()
        ctx.products = [tidy]
        let check = orderImportCheck(try order([("TIDY", "2"), ("tidy ", "3")]), context: ctx)
        XCTAssertEqual(check.blockers, [])
        XCTAssertEqual(check.lines.map(\.quantity), [5, 1])
        XCTAssertEqual(check.lines.map(\.type), ["PRINT", "STATIONERY"])
        XCTAssertEqual(check.itemsSummary, "5 × Desk Tidy, 1 × Packing slip", "stationery is shown in the preview")
        let items = try XCTUnwrap(check.body?["items"] as? [[String: Any]])
        XCTAssertEqual(items.count, 2)
    }

    func testTwoSKUsSharingASlipGetItOnce() throws {
        var tidy = product("Desk Tidy", sku: "TIDY")
        var clip = product("Cable Clip", sku: "clip-2")
        tidy.lines.append(slipLine())
        clip.lines.append(slipLine())
        var ctx = context()
        ctx.products = [tidy, clip]
        let shared = orderImportCheck(try order([("TIDY", "1"), ("CLIP-2", "2")]), context: ctx)
        XCTAssertEqual(shared.blockers, [])
        XCTAssertEqual(shared.lines.map(\.type), ["PRINT", "STATIONERY", "PRINT"])
        XCTAssertEqual(shared.lines.map(\.quantity), [1, 1, 2])
        XCTAssertEqual(shared.itemsSummary, "1 × Desk Tidy, 1 × Packing slip, 2 × Cable Clip")

        // A different slip (or image) is a different item, so both are kept.
        ctx.products[1].lines[1] = slipLine("slip-2")
        XCTAssertEqual(orderImportCheck(try order([("TIDY", "1"), ("CLIP-2", "2")]), context: ctx).lines.filter { $0.type == "STATIONERY" }.count, 2)
        ctx.products[1].lines[1] = slipLine()
        ctx.products[1].lines[1].imageURL = "https://example.com/other.png"
        XCTAssertEqual(orderImportCheck(try order([("TIDY", "1"), ("CLIP-2", "2")]), context: ctx).lines.filter { $0.type == "STATIONERY" }.count, 2)
    }

    func testTheUnitCapAppliesToEachProductsTotal() throws {
        let over = orderImportCheck(try order([("TIDY", "6000"), ("TIDY", "5000")]), context: context())
        XCTAssertEqual(over.blockers, ["This order has more than 10,000 units of “Desk Tidy” in total."])
        XCTAssertNil(over.body)
        XCTAssertEqual(orderImportCheck(try order([("TIDY", "6000"), ("TIDY", "4000")]), context: context()).lines.map(\.quantity), [10_000])
    }

    // MARK: Match products

    func testUnmatchedKeysListEachSKUOrNameOnce() throws {
        var first = try order([("NOPE", "1"), ("", "1"), ("TIDY", "1")], name: ["", "Gift  wrap", ""])
        first.items.append(OrderImportItem(sku: "", quantityText: "1", itemName: "", row: 9))
        var second = try order([("nope ", "2"), ("", "1")], name: ["", "gift wrap"])
        second = OrderImportOrder(source: second.source, sourceOrderID: "#2", items: second.items)
        let keys = orderImportUnmatchedKeys([first, second], products: products)
        XCTAssertEqual(keys.map(\.id), ["sku|nope", "name|gift wrap"])
        XCTAssertEqual(keys.map(\.display), ["NOPE", "Gift wrap"])
        XCTAssertEqual(keys.map(\.orderCount), [2, 2])
        XCTAssertEqual(orderImportMissingSKUs(keys), ["NOPE"])
        XCTAssertEqual(orderImportMissingSKUSummary(["A", "B", "C"]), "3 SKUs have no saved product: A, B, C")
        XCTAssertEqual(orderImportMissingSKUSummary(["A"]), "1 SKU has no saved product: A")
        XCTAssertNil(orderImportMissingSKUSummary([]))
    }

    func testChosenProductsMatchOnlyWhatTheUserChose() throws {
        var ctx = context()
        let tidy = ctx.products[0]
        let unmatched = try order([("NOPE", "2"), ("", "1")], name: ["", "Shipping protection"])
        XCTAssertFalse(orderImportCheck(unmatched, context: ctx).canTick, "nothing is matched without a choice")

        ctx.productChoices = ["sku|nope": .product(tidy.id), "name|shipping protection": .leaveOut]
        let check = orderImportCheck(unmatched, context: ctx)
        XCTAssertEqual(check.blockers, [])
        XCTAssertTrue(check.usesProductChoice)
        XCTAssertEqual(check.lines.map(\.quantity), [2])
        XCTAssertEqual(check.lines.first?.reference, "file-TIDY")
        XCTAssertEqual(check.itemsSummary, "2 × Desk Tidy")
        XCTAssertTrue(check.notes.contains("SKU NOPE uses “Desk Tidy”, as you chose."))
        XCTAssertTrue(check.notes.contains("The “Shipping protection” is left out of the draft, as you chose."))

        // A choice never overrides a saved product that matches by SKU.
        ctx.productChoices = ["sku|clip-2": .product(tidy.id)]
        XCTAssertEqual(orderImportCheck(try order([("CLIP-2", "1")]), context: ctx).lines.first?.reference, "file-clip-2")
        // A choice of a product that no longer exists matches nothing.
        ctx.productChoices = ["sku|nope": .product(UUID())]
        XCTAssertFalse(orderImportCheck(try order([("NOPE", "1")]), context: ctx).canTick)
        // Leaving out every item leaves nothing to draft.
        ctx.productChoices = ["sku|nope": .leaveOut]
        XCTAssertEqual(orderImportCheck(try order([("NOPE", "1")]), context: ctx).blockers,
                       ["Every item of this order is left out, so there’s nothing to draft."])
        // Units of a chosen product and its SKU match are summed into one line.
        ctx.productChoices = ["sku|nope": .product(tidy.id)]
        XCTAssertEqual(orderImportCheck(try order([("NOPE", "2"), ("TIDY", "3")]), context: ctx).lines.map(\.quantity), [5])
    }

    func testItemsWithoutSKUOrNameCantBeMatched() throws {
        let check = orderImportCheck(try order([("", "1")]), context: context())
        XCTAssertEqual(check.blockers, ["The item on row 2 has no SKU or name. Add the SKU in your shop, or create this draft by hand."])
        XCTAssertNil(orderImportMatchKey(for: OrderImportItem(sku: " ", quantityText: "1", itemName: " ", row: 2)))
    }

    func testOrdersAChoiceUnblocksAreTicked() {
        var blocked = OrderImportCheck()
        blocked.blockers = ["x"]
        var warned = OrderImportCheck()
        warned.warnings = ["y"]
        let ready = OrderImportCheck()
        let ticked = orderImportNewlyTickable(
            before: ["a": blocked, "b": blocked, "c": ready, "d": blocked],
            after: ["a": ready, "b": warned, "c": ready, "d": blocked])
        XCTAssertEqual(ticked, ["a"], "only orders the choice unblocked, and that need no second look")
    }

    // MARK: Drafts

    func testShowDraftsFilterAndWording() {
        let filter = orderImportDraftsFilter()
        XCTAssertEqual(filter.status, "DRAFT")
        XCTAssertNil(filter.startDate)
        XCTAssertNil(filter.endDate)
        XCTAssertEqual(filter.sortOrder, "desc")
        for text in [orderImportUnknownAdvice, orderImportDuplicateReason(
            OrderImportOrder(source: .etsy, sourceOrderID: "1"), ledger: {
                var ledger = OrderImportLedger(); ledger.record(.unknown, source: .etsy, sourceOrderID: "1"); return ledger
            }(), loadedKeys: []) ?? ""] {
            XCTAssertFalse(text.contains("Orders (Drafts)"), text)
            XCTAssertTrue(text.contains("Show Drafts"), text)
        }
    }
}
