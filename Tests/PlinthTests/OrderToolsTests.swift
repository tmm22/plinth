import XCTest
@testable import Plinth

final class OrderToolsTests: XCTestCase {
    // MARK: Sorting

    private func row(_ id: String, created: String? = nil, total: Any? = nil, extra: [String: Any] = [:]) -> OrderTableRow {
        var values: [String: Any] = ["publicId": id]
        if let created { values["createdAt"] = created }
        if let total { values["totalCost"] = total }
        values.merge(extra) { _, new in new }
        return OrderTableRow(record: Record(values: values))
    }

    func testCreatedSortIsChronologicalAcrossMonthsAndYears() {
        let rows = [
            row("oct3", created: "2026-10-03T09:00:00Z"),
            row("dec2025", created: "2025-12-05T09:00:00.123Z"),
            row("oct21", created: "2026-10-21T09:00:00Z"),
            row("missing"),
            row("jan", created: "2026-01-15")
        ]
        // Display strings sort "Dec…" before "Jan…" before "Oct 21" before "Oct 3", which is wrong.
        let newest = orderTableRowsSorted(rows, using: orderTableDefaultSort(serverSortOrder: "desc")).map(\.id)
        XCTAssertEqual(newest, ["oct21", "oct3", "jan", "dec2025", "missing"])
        let oldest = orderTableRowsSorted(rows, using: orderTableDefaultSort(serverSortOrder: "asc")).map(\.id)
        XCTAssertEqual(oldest, ["missing", "dec2025", "jan", "oct3", "oct21"])
    }

    func testDefaultSortFollowsServerSortSetting() {
        XCTAssertEqual(orderTableDefaultSort(serverSortOrder: "asc").first?.order, .forward)
        XCTAssertEqual(orderTableDefaultSort(serverSortOrder: "ASC").first?.order, .forward)
        XCTAssertEqual(orderTableDefaultSort(serverSortOrder: "desc").first?.order, .reverse)
        XCTAssertEqual(orderTableDefaultSort(serverSortOrder: "").first?.order, .reverse)
        // Rows Slant returned already in its createdAt order stay in that order, including ties.
        let server = [
            row("a", created: "2026-10-21T10:00:00Z"), row("b", created: "2026-10-21T10:00:00Z"),
            row("c", created: "2026-10-20T10:00:00Z")
        ]
        XCTAssertEqual(orderTableRowsSorted(server, using: orderTableDefaultSort(serverSortOrder: "desc")).map(\.id), ["a", "b", "c"])
        XCTAssertEqual(orderTableRowsSorted(server, using: []).map(\.id), ["a", "b", "c"])
    }

    func testTotalSortIsNumericAcrossMagnitudes() {
        let rows = [
            row("hundred", total: "100.00"),
            row("twenty", total: "20.00"),
            row("three", total: NSNumber(value: 3.5)),
            row("thousand", total: "1000.00"),
            row("none"),
            row("summed", extra: ["printingCost": "4.00", "deliveryCost": "5.50"])
        ]
        let comparator = [KeyPathComparator(\OrderTableRow.totalSortKey, order: .forward)]
        XCTAssertEqual(orderTableRowsSorted(rows, using: comparator).map(\.id), ["none", "three", "summed", "twenty", "hundred", "thousand"])
        let reversed = [KeyPathComparator(\OrderTableRow.totalSortKey, order: .reverse)]
        XCTAssertEqual(orderTableRowsSorted(rows, using: reversed).map(\.id), ["thousand", "hundred", "twenty", "summed", "three", "none"])
    }

    func testTotalAmountMatchesDisplayedTotalPrecedence() {
        XCTAssertEqual(orderTotalAmount(["total": "12.34", "totalCost": "99.00"]), Decimal(string: "12.34"))
        XCTAssertEqual(orderTotalAmount(["totalCost": "7.10"]), Decimal(string: "7.10"))
        XCTAssertEqual(orderTotalAmount(["printingCost": "2.00"]), 2)
        XCTAssertNil(orderTotalAmount(["total": NSNull()]))
        XCTAssertNil(orderTotalAmount([:]))
        XCTAssertEqual(orderTotalMoney(["total": NSNull()]), "—")
    }

    func testTimestampParsingAndCreatedDisplayAgree() {
        XCTAssertNotNil(orderTimestamp("2026-10-03T09:00:00Z"))
        XCTAssertNotNil(orderTimestamp("2026-10-03T09:00:00.5Z"))
        XCTAssertNotNil(orderTimestamp("2026-10-03"))
        XCTAssertNil(orderTimestamp("soon"))
        XCTAssertNil(orderTimestamp(""))
        XCTAssertEqual(orderCreatedRaw(["created_at": "2026-10-03T09:00:00Z"]), "2026-10-03T09:00:00Z")
        XCTAssertNil(orderCreatedDisplay(["createdAt": ""]))
        XCTAssertEqual(row("x", created: "garbage").created, "garbage")
        XCTAssertEqual(row("x", created: "garbage").createdSortKey, orderMissingDateSortKey)
    }

    // MARK: Detail facts

    func testDetailFactsOnlyShowFieldsSlantReturned() {
        XCTAssertTrue(orderDetailFacts([:]).isEmpty)
        XCTAssertTrue(orderDetailFacts(["processedAt": NSNull(), "options": NSNull(), "fulfillment": ["deliveryInstructions": "  "]]).isEmpty)
        let facts = orderDetailFacts([
            "processedAt": "2026-10-03T09:00:00Z",
            "options": ["shippingProvider": "SHIPSTATION"],
            "fulfillment": ["deliveryInstructions": " Leave at the side door "]
        ])
        XCTAssertEqual(facts.map(\.0), ["Placed", "Shipping provider", "Delivery instructions"])
        XCTAssertEqual(facts[1].1, "ShipStation")
        XCTAssertEqual(facts[2].1, "Leave at the side door")
        XCTAssertEqual(orderDetailFacts(["options": ["shippingProvider": "FEDEX_DIRECT"]]).first?.1, "FEDEX_DIRECT")
    }

    func testItemStatusTitles() {
        XCTAssertEqual(orderItemStatusTitle(["status": "PROCESSING"]), "Processing")
        XCTAssertEqual(orderItemStatusTitle(["status": "ready"]), "Ready")
        XCTAssertEqual(orderItemStatusTitle(["status": "SHIPPED"]), "Shipped")
        XCTAssertEqual(orderItemStatusTitle(["status": "DELIVERED"]), "Delivered")
        XCTAssertEqual(orderItemStatusTitle(["status": "ON_HOLD"]), "On Hold")
        XCTAssertNil(orderItemStatusTitle([:]))
        XCTAssertNil(orderItemStatusTitle(["status": ""]))
        XCTAssertNil(orderItemStatusTitle(["status": NSNull()]))
    }

    // MARK: Copied item options

    func testDuplicatedOptionsAreSummarisedAndRemovable() throws {
        let order = Record(values: ["publicId": "SLANT_1", "items": [[
            "type": "PRINT", "publicFileServiceId": "file-1", "filamentId": "fil-1", "quantity": 2,
            "options": ["slicerOptions": ["infill": 20], "note": "matte"]
        ]]])
        let line = try XCTUnwrap(orderLinesForReorder(order).lines.first)
        let summary = orderLineOptionsSummary(line.optionsJSON)
        XCTAssertEqual(summary.map(\.key), ["note", "slicerOptions"])
        XCTAssertEqual(summary.map(\.value), ["matte", #"{"infill":20}"#])
        XCTAssertNotNil(try line.payload()["options"])

        let removed = orderLineRemovingOptions(line)
        XCTAssertTrue(orderLineOptionsSummary(removed.optionsJSON).isEmpty)
        XCTAssertNil(try removed.payload()["options"])
        XCTAssertEqual(try removed.payload()["publicFileServiceId"] as? String, "file-1")
        XCTAssertEqual(try removed.payload()["quantity"] as? Int, 2)
        // Removing copied options is an edit the discard check protects.
        XCTAssertFalse(orderLinesHaveSameContent([line], [removed]))
    }

    func testOptionsSummaryEmptyAndInvalid() {
        XCTAssertTrue(orderLineOptionsSummary("{}").isEmpty)
        XCTAssertTrue(orderLineOptionsSummary("").isEmpty)
        XCTAssertTrue(orderLineOptionsSummary(OrderLine().optionsJSON).isEmpty)
        XCTAssertEqual(orderLineOptionsSummary("[1,2]").first?.key, "Options")
        XCTAssertEqual(orderLineOptionsSummary("not json").first?.value, "Not a valid JSON object")
        XCTAssertEqual(orderLineOptionsSummary(#"{"a":null,"b":true,"c":"https://x.test/y"}"#).map(\.value), ["null", "true", "https://x.test/y"])
    }

    // MARK: Status coverage against the bundled spec

    private func spec() throws -> [String: Any] {
        let url = try XCTUnwrap(EndpointCatalog.specificationURL())
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    func testStatusFilterOffersExactlyTheValuesGetOrdersAccepts() throws {
        let document = try spec()
        let get = try XCTUnwrap(((document["paths"] as? [String: Any])?["/orders"] as? [String: Any])?["get"] as? [String: Any])
        let parameters = try XCTUnwrap(get["parameters"] as? [[String: Any]])
        let status = try XCTUnwrap(parameters.first { $0["name"] as? String == "status" })
        let accepted = try XCTUnwrap((status["schema"] as? [String: Any])?["enum"] as? [String])
        // Live Slant refuses any other value with 400 "Invalid status filter" (28 Oct 2026).
        XCTAssertEqual(orderStatusFilterOptions, accepted)
        XCTAssertEqual(orderStatusFilterOptions, ["DRAFT", "SUBMITTED", "PRINTING", "SHIPPED", "CANCELLED"])
        XCTAssertTrue(orderLegacyStatuses.isDisjoint(with: orderStatusFilterOptions))
    }

    func testEveryDocumentedOrderStatusHasALabelAndCancelCopy() throws {
        let schemas = try XCTUnwrap((try spec()["components"] as? [String: Any])?["schemas"] as? [String: Any])
        let order = try XCTUnwrap(((schemas["Order"] as? [String: Any])?["properties"] as? [String: Any])?["status"] as? [String: Any])
        let statuses = try XCTUnwrap(order["enum"] as? [String])
        XCTAssertEqual(statuses, orderLiveStatuses)
        XCTAssertEqual(Set(statuses).union(orderLegacyStatuses), orderKnownStatuses)
        for status in statuses + orderLegacyStatuses.sorted() {
            let title = orderStatusTitle(status)
            XCTAssertFalse(title.isEmpty || title == "Order" || title.contains("_"), status)
            XCTAssertFalse(orderCancelButtonBaseTitle(status).isEmpty, status)
            XCTAssertFalse(orderCancelSheetBody(status).isEmpty, status)
        }
        let item = try XCTUnwrap(((schemas["OrderItem"] as? [String: Any])?["properties"] as? [String: Any])?["status"] as? [String: Any])
        for status in try XCTUnwrap(item["enum"] as? [String]) {
            let title = try XCTUnwrap(orderItemStatusTitle(["status": status]))
            XCTAssertFalse(title.contains("_"), status)
        }
    }

    // MARK: CSV

    /// Minimal RFC 4180 reader used to check the writer round-trips awkward values.
    private func parseCSV(_ text: String) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var quoted = false
        var chars = Array(text)
        var index = 0
        while index < chars.count {
            let char = chars[index]
            if quoted {
                if char == "\"" {
                    if index + 1 < chars.count, chars[index + 1] == "\"" { field.append("\""); index += 1 } else { quoted = false }
                } else { field.append(char) }
            } else if char == "\"" {
                quoted = true
            } else if char == "," {
                row.append(field); field = ""
            } else if char == "\r\n" || char == "\n" {
                row.append(field); field = ""; rows.append(row); row = []
            } else {
                field.append(char)
            }
            index += 1
        }
        if !field.isEmpty || !row.isEmpty { row.append(field); rows.append(row) }
        chars.removeAll()
        return rows
    }

    private let sampleOrder: [String: Any] = [
        "publicId": "SLANT_ABC",
        "status": "SHIPPED",
        "createdAt": "2026-10-03T09:00:00.000Z",
        "printingCost": "10.00",
        "deliveryCost": "5.5",
        "items": [
            ["name": "Bracket, large", "quantity": 2],
            ["name": "Clip \"mini\"\nv2", "quantity": 1]
        ],
        "fulfillment": ["provider": "USPS", "trackingNumbers": ["1Z1", "1Z2"]],
        "customer": ["details": [
            "email": "pat@example.com",
            "address": ["name": "Pat Example", "line1": "1 Main St", "line2": "", "city": "Springfield", "state": "IL", "zip": "62701", "country": "US"]
        ]]
    ]

    func testCSVExcludesAddressesByDefault() {
        let csv = ordersCSV([Record(values: sampleOrder)], includeAddresses: false)
        for secret in ["Pat Example", "pat@example.com", "1 Main St", "Springfield", "62701", "Recipient", "Email"] {
            XCTAssertFalse(csv.contains(secret), secret)
        }
        let rows = parseCSV(csv)
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0], ordersCSVBaseColumns)
        XCTAssertEqual(rows[1], [
            "SLANT_ABC", "2026-10-03T09:00:00Z", "SHIPPED", "3", "2 × Bracket, large; 1 × Clip \"mini\"\nv2",
            "10.00", "5.50", "15.50", "USD", "USPS", "1Z1; 1Z2"
        ])
        XCTAssertTrue(csv.hasSuffix("\r\n"))
    }

    func testCSVIncludesAddressesOnlyWhenOptedIn() {
        let rows = parseCSV(ordersCSV([Record(values: sampleOrder)], includeAddresses: true))
        XCTAssertEqual(rows[0], ordersCSVBaseColumns + ordersCSVAddressColumns)
        XCTAssertEqual(Array(rows[1].suffix(9)), ["Pat Example", "pat@example.com", "1 Main St", "", "Springfield", "IL", "62701", "US", ""])
    }

    func testCSVMetadataIsOptInWithAddresses() {
        var order = sampleOrder
        order["metadata"] = ["shopOrder": "#1001", "customer": ["ref": "C-9"]]
        let without = ordersCSV([Record(values: order)], includeAddresses: false)
        XCTAssertFalse(without.contains("1001"))
        XCTAssertFalse(without.contains("Metadata"))
        let rows = parseCSV(ordersCSV([Record(values: order)], includeAddresses: true))
        XCTAssertEqual(rows[0].last, "Metadata")
        XCTAssertEqual(rows[1].last, ##"{"customer":{"ref":"C-9"},"shopOrder":"#1001"}"##)
        XCTAssertEqual(ordersCSVMetadata(NSNull()), "")
        XCTAssertEqual(ordersCSVMetadata([String: Any]()), "")
        XCTAssertEqual(ordersCSVMetadata(nil), "")
        // A metadata value that looks like a formula is still neutralised by the field guard.
        XCTAssertEqual(csvField(ordersCSVMetadata("=1+1")), "'=1+1")
    }

    func testCSVPartialExportNoticeAndMenu() {
        XCTAssertEqual(ordersCSVPartialNotice(moreOnServer: true), "Only loaded orders are exported. Load more to include older ones.")
        XCTAssertNil(ordersCSVPartialNotice(moreOnServer: false))
        XCTAssertTrue(ordersExportMenuEnabled(destination: .orders, ordersLoaded: true, sheetPresented: false))
        XCTAssertFalse(ordersExportMenuEnabled(destination: .orders, ordersLoaded: false, sheetPresented: false))
        XCTAssertFalse(ordersExportMenuEnabled(destination: .orders, ordersLoaded: true, sheetPresented: true))
        XCTAssertFalse(ordersExportMenuEnabled(destination: .models, ordersLoaded: true, sheetPresented: false))
    }

    func testCSVEmptyListIsHeaderOnly() {
        XCTAssertEqual(ordersCSV([], includeAddresses: false), ordersCSVBaseColumns.joined(separator: ",") + "\r\n")
        XCTAssertEqual(parseCSV(ordersCSV([], includeAddresses: true)), [ordersCSVBaseColumns + ordersCSVAddressColumns])
    }

    func testCSVMissingFieldsStayBlank() {
        let rows = parseCSV(ordersCSV([Record(values: ["publicId": "SLANT_EMPTY"])], includeAddresses: true))
        XCTAssertEqual(rows[1], ["SLANT_EMPTY"] + Array(repeating: "", count: ordersCSVBaseColumns.count + ordersCSVAddressColumns.count - 1))
        // A quantity that isn't a whole number leaves the count blank rather than guessing.
        let fuzzy = parseCSV(ordersCSV([Record(values: ["publicId": "X", "items": [["name": "A", "quantity": "lots"]], "createdAt": "later"])], includeAddresses: false))
        XCTAssertEqual(fuzzy[1][1], "later")
        XCTAssertEqual(fuzzy[1][3], "")
        XCTAssertEqual(fuzzy[1][4], "lots × A")
    }

    func testCSVCurrencyUsesOrderValueWhenPresent() {
        let rows = parseCSV(ordersCSV([
            Record(values: ["publicId": "A", "totalCost": "1.00"]),
            Record(values: ["publicId": "B", "totalCost": "2.00", "currency": "EUR"])
        ], includeAddresses: false))
        XCTAssertEqual(rows[1][8], "USD")
        XCTAssertEqual(rows[2][8], "EUR")
    }

    func testCSVFieldEscapingAndFormulaGuard() {
        XCTAssertEqual(csvField("plain"), "plain")
        XCTAssertEqual(csvField("a,b"), "\"a,b\"")
        XCTAssertEqual(csvField("say \"hi\""), "\"say \"\"hi\"\"\"")
        XCTAssertEqual(csvField("two\nlines"), "\"two\nlines\"")
        XCTAssertEqual(csvField("=cmd|' /C calc'!A0"), "'=cmd|' /C calc'!A0")
        XCTAssertEqual(csvField("+1 555"), "'+1 555")
        XCTAssertEqual(csvField("-2+3"), "'-2+3")
        XCTAssertEqual(csvField("@SUM(A1)"), "'@SUM(A1)")
        XCTAssertEqual(csvField("\t=x"), "'\t=x")
        XCTAssertEqual(csvField(" =x"), "' =x")
        XCTAssertEqual(csvField(" padded"), "\" padded\"")
        XCTAssertEqual(csvField("=a,b"), "\"'=a,b\"")
        XCTAssertEqual(csvField("-5.00"), "-5.00")
        XCTAssertEqual(csvField("12"), "12")
        XCTAssertEqual(csvField(""), "")
    }

    func testCSVRoundTripsHostileItemNames() {
        let hostile = "=HYPERLINK(\"http://x\",\"y\"), \"q\"\r\nnext"
        let csv = ordersCSV([Record(values: ["publicId": "@id", "items": [["name": hostile, "quantity": 1]]])], includeAddresses: false)
        let rows = parseCSV(csv)
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[1].count, ordersCSVBaseColumns.count)
        XCTAssertEqual(rows[1][0], "'@id")
        XCTAssertEqual(rows[1][4], "1 × " + hostile)
    }

    func testCSVActivityDetailNeverIncludesOrderContents() {
        XCTAssertEqual(ordersCSVActivityDetail(count: 1, includeAddresses: false), "1 order")
        XCTAssertEqual(ordersCSVActivityDetail(count: 3, includeAddresses: true), "3 orders, including recipients, addresses and metadata")
        XCTAssertTrue(ordersCSVDefaultFileName().hasSuffix(".csv"))
    }

    // MARK: Postcodes

    func testPostcodeWarningsForKnownFormats() {
        let valid: [(String, String)] = [
            ("US", "12345"), ("US", "12345-6789"), ("CA", "K1A 0B1"), ("CA", "k1a0b1"), ("GB", "SW1A 1AA"),
            ("GB", "M1 1AE"), ("GB", "gir 0aa"), ("AU", "2000"), ("NZ", "6011"), ("DE", "10115"), ("FR", "75001"),
            ("NL", "1012 AB"), ("NL", "1012ab"), ("JP", "100-0001"), ("JP", "1000001"), ("IE", "D02 X285"), ("IE", "D6W1234"),
            ("us", " 12345 ")
        ]
        for (country, code) in valid { XCTAssertNil(postcodeFormatWarning(code, country: country), "\(country) \(code)") }
        let invalid: [(String, String)] = [
            ("US", "1234"), ("US", "12345-67"), ("CA", "D1A 0B1"), ("CA", "12345"), ("GB", "12345"), ("AU", "20000"),
            ("NZ", "AB12"), ("DE", "1011"), ("FR", "7500"), ("NL", "0123 AB"), ("JP", "10-00001"), ("IE", "12345")
        ]
        for (country, code) in invalid {
            let warning = postcodeFormatWarning(code, country: country)
            XCTAssertNotNil(warning, "\(country) \(code)")
            XCTAssertTrue(warning?.contains("you can still create the draft") == true)
        }
    }

    func testPostcodeWarningWaitsWhileTypingUntilMinimumLength() {
        // While the field has focus, a short value isn't judged yet.
        XCTAssertNil(postcodeFormatWarning("123", country: "US", whileEditing: true))
        XCTAssertNil(postcodeFormatWarning("SW1", country: "GB", whileEditing: true))
        XCTAssertNil(postcodeFormatWarning("100-00", country: "JP", whileEditing: true), "hyphens don't count towards the length")
        // Leaving the field shows it.
        XCTAssertNotNil(postcodeFormatWarning("123", country: "US", whileEditing: false))
        // Long enough to judge: shown while typing too.
        XCTAssertNotNil(postcodeFormatWarning("123456", country: "US", whileEditing: true))
        XCTAssertNotNil(postcodeFormatWarning("D1A0B1", country: "CA", whileEditing: true))
        XCTAssertNil(postcodeFormatWarning("12345", country: "US", whileEditing: true))
        XCTAssertNil(postcodeFormatWarning("M1 1AE", country: "GB", whileEditing: true))
    }

    func testItemStatusShownOnlyWhenItemsDiffer() {
        XCTAssertFalse(orderItemStatusesDiffer([]))
        XCTAssertFalse(orderItemStatusesDiffer([["status": "SHIPPED"]]))
        XCTAssertFalse(orderItemStatusesDiffer([["status": "SHIPPED"], ["status": "shipped"]]))
        XCTAssertFalse(orderItemStatusesDiffer([[:], [:]]))
        XCTAssertTrue(orderItemStatusesDiffer([["status": "SHIPPED"], ["status": "PROCESSING"]]))
        XCTAssertTrue(orderItemStatusesDiffer([["status": "READY"], [:]]))
    }

    func testPostcodeWarningSkipsUnknownCountriesAndEmptyValues() {
        XCTAssertNil(postcodeFormatWarning("ABC", country: "SE"))
        XCTAssertNil(postcodeFormatWarning("ABC", country: ""))
        XCTAssertNil(postcodeFormatWarning("ABC", country: orderCountryOtherTag))
        XCTAssertNil(postcodeFormatWarning("", country: "US"))
        XCTAssertNil(postcodeFormatWarning("   ", country: "GB"))
        XCTAssertEqual(postcodeCheckedCountryCodes, ["US", "CA", "GB", "AU", "NZ", "DE", "FR", "NL", "JP", "IE"])
    }

    func testPostcodeWarningNeverChangesWhatTheDraftRequires() throws {
        XCTAssertNotNil(postcodeFormatWarning("1234", country: "US"))
        let body = try orderDraftPayload(
            platformID: "p", ownerID: "", email: "pat@example.com", recipientName: "Pat",
            line1: "1 Main St", line2: "", city: "Springfield", state: "IL", zip: "1234", country: "US",
            paymentID: "", metadata: [:], options: [:], lines: [OrderLine(reference: "f", filamentID: "m")]
        )
        let address = ((body["customer"] as? [String: Any])?["details"] as? [String: Any])?["address"] as? [String: Any]
        XCTAssertEqual(address?["zip"] as? String, "1234")
        XCTAssertEqual(address?["country"] as? String, "US")
    }

    // MARK: Orders list and detail layout

    func testSearchHintExplainsLoadedVersusAllOrders() {
        XCTAssertNil(orderSearchHint(typed: "", searchActive: false))
        XCTAssertNil(orderSearchHint(typed: "   ", searchActive: false))
        // While typing, the box filters the loaded orders and Return asks Slant, which finds order numbers.
        let typing = orderSearchHint(typed: "ada", searchActive: false)
        XCTAssertEqual(typing, "Showing loaded orders that match. Press Return to look up an order number on Slant.")
        // After Return, results come from Slant, with the way back.
        let searched = orderSearchHint(typed: "ada", searchActive: true)
        XCTAssertEqual(searched, "Showing what Slant found. Clear the search to return to the list.")
        XCTAssertFalse(searched?.contains("Press Return") ?? true)
    }

    func testTrackingHiddenOnlyWhenThereIsNothingToTrack() {
        for status in ["DRAFT", "draft", "CANCELED", "CANCELLED", "PAYMENT_ERROR"] {
            XCTAssertFalse(orderDetailShowsTracking(status: status, hasTrackingDetails: false), status)
        }
        for status in ["PAID", "QUEUED", "PRINTING", "AWAITING_SHIPMENT", "SHIPPED", "DELIVERED", "", "SOMETHING_NEW"] {
            XCTAssertTrue(orderDetailShowsTracking(status: status, hasTrackingDetails: false), status)
        }
        // Tracking details Slant returned are never hidden, whatever the status.
        XCTAssertTrue(orderDetailShowsTracking(status: "CANCELED", hasTrackingDetails: true))
        XCTAssertTrue(orderDetailShowsTracking(status: "DRAFT", hasTrackingDetails: true))
    }

    func testReviewLargeQuantityNoticeForScrolledLists() {
        let small: [String: Any] = ["quantity": 2, "name": "Bracket"]
        let large: [String: Any] = ["quantity": 30, "name": "Bracket"]
        XCTAssertNil(orderReviewLargeQuantityNotice([]))
        XCTAssertNil(orderReviewLargeQuantityNotice([large]), "a single item's own flag is always in view")
        XCTAssertNil(orderReviewLargeQuantityNotice(Array(repeating: small, count: 30)))
        XCTAssertEqual(orderReviewLargeQuantityNotice(Array(repeating: small, count: 29) + [large]), "1 item has a large quantity. Check it above.")
        XCTAssertEqual(orderReviewLargeQuantityNotice([large, small, large]), "2 items have a large quantity. Check them above.")
    }

    // MARK: Draft composer copy

    func testComposerHeading() {
        XCTAssertEqual(orderComposerHeading(sourceOrderNumber: nil), "New order draft")
        XCTAssertEqual(orderComposerHeading(sourceOrderNumber: "  "), "New order draft")
        XCTAssertEqual(orderComposerHeading(sourceOrderNumber: "SLANT_9"), "Duplicate of order SLANT_9")
    }

    func testReusedAddressLineNamesRecipientAndCity() {
        let full = DeliveryDetails(email: "ada@example.com", name: " Ada Lovelace ", line1: "1 Main St", city: "London", countrySelection: "GB")
        XCTAssertEqual(orderComposerReusedAddressLine(full), "Same address as your last draft: Ada Lovelace, London")
        XCTAssertEqual(orderComposerReusedAddressLine(DeliveryDetails(name: "Ada", countrySelection: "")), "Same address as your last draft: Ada")
        XCTAssertEqual(orderComposerReusedAddressLine(DeliveryDetails(email: "ada@example.com", countrySelection: "")),
                       "Same address as your last draft: ada@example.com")
        XCTAssertEqual(orderComposerReusedAddressLine(DeliveryDetails(countrySelection: "")), "Same address as your last draft")
    }

    func testAdvancedOptionsOpenWhenDuplicateCopiedValues() {
        XCTAssertFalse(orderComposerAdvancedStartsExpanded(shippingProvider: "", metadataFields: []))
        XCTAssertFalse(orderComposerAdvancedStartsExpanded(shippingProvider: " ", metadataFields: [OrderMetadataField()]))
        XCTAssertTrue(orderComposerAdvancedStartsExpanded(shippingProvider: "", metadataFields: [OrderMetadataField(key: "shop", value: "")]))
        // A duplicated order's shipping provider is copied into Advanced, so it starts open rather than hidden.
        let prefill = orderComposerPrefill(reordering: Record(values: ["publicId": "S1", "options": ["shippingProvider": "shipstation"]]))
        XCTAssertEqual(prefill.shippingProvider, "SHIPSTATION")
        XCTAssertTrue(orderComposerAdvancedStartsExpanded(shippingProvider: prefill.shippingProvider, metadataFields: []))
    }
}
