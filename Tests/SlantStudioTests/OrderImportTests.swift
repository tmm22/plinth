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
        XCTAssertEqual(orderImportCheck(order, context: context()).blockers, ["No saved product has SKU NOPE. Add it in Saved Products."])
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
}
