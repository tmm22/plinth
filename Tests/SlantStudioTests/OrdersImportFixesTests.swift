import XCTest
@testable import SlantStudio

/// Round 5 review fixes to Orders and Import Orders: left-out items and the buyer's amounts, the unconfirmed-draft
/// guard's overflow, Look for Draft on Slant, the import sheet's sections, Paste Address and the Spending Report.
final class OrdersImportFixesTests: XCTestCase {
    // MARK: Left-out items and the buyer's amounts

    private let etsyHeader = "Sale Date,Item Name,Buyer,Quantity,Price,Coupon Code,Coupon Details,Discount Amount,Shipping Discount,Order Shipping,Order Sales Tax,Item Total,Currency,Transaction ID,Listing ID,Date Paid,Date Shipped,Ship Name,Ship Address1,Ship Address2,Ship City,Ship State,Ship Zipcode,Ship Country,Order ID,Variations,SKU"

    private func etsyRow(_ quantity: String, _ price: String, shipping: String = "4.50", sku: String) -> String {
        "10/01/26,Desk Tidy,ana,\(quantity),\(price),,,0.00,0.00,\(shipping),0.80,,USD,1,2,10/01/26,,Ana Lee,1 Main St,,Austin,TX,78701,United States,T-1001,,\(sku)"
    }

    private func dec(_ text: String) -> Decimal { Decimal(string: text, locale: Locale(identifier: "en_US_POSIX"))! }

    func testLeavingItemsOutDropsTheItemTotalAndUnits() throws {
        let parse = try orderImportParse(data: Data([etsyHeader, etsyRow("2", "10.00", shipping: "4.50", sku: "TIDY"),
                                                    etsyRow("1", "5.00", shipping: "0", sku: "GIFT")].joined(separator: "\n").utf8))
        let order = try XCTUnwrap(parse.orders.first)
        let whole = try XCTUnwrap(importedSaleAmountsByOrder(parse.orders)[order.id])
        XCTAssertEqual(whole.itemTotal, dec("25.00"))
        XCTAssertEqual(whole.unitsSold, 3)

        let partial = try XCTUnwrap(importedSaleAmountsByOrder(parse.orders, leavingOutItemsIn: [order.id])[order.id])
        XCTAssertNil(partial.itemTotal, "the item total covered items Slant isn't making")
        XCTAssertNil(partial.unitsSold)
        XCTAssertEqual(partial.shipping, dec("4.50"))
        XCTAssertEqual(partial.notes.first, importedSaleLeftOutNote)
        XCTAssertTrue(importedSaleCaption(partial).contains("Some items weren’t in this draft, so enter what the buyer paid for the rest."))
        // The pay review shows no estimate without an item total.
        let draft: [String: Any] = ["status": "DRAFT", "totalCost": "10.00", "currency": "USD"]
        XCTAssertNil(importedSaleReviewEstimate(partial, order: draft, preset: .none, rates: ProfitFeeRates()))
        // Prefill leaves the item total and units for the seller.
        let prefill = importedSalePrefill(partial, itemText: "", shippingText: "", unitsText: "1", decimalSeparator: ".")
        XCTAssertNil(prefill.itemText)
        XCTAssertNil(prefill.unitsText)
        XCTAssertEqual(prefill.shippingText, "4.50")
    }

    func testAmountsForADraftWithNothingLeftAreDropped() {
        var amounts = ImportedSaleAmounts(source: .etsy, sourceOrderID: "1")
        amounts.itemTotal = 10
        amounts.unitsSold = 2
        amounts.notes = ["Enter the item total: x", "Enter the shipping charged: y"]
        XCTAssertEqual(importedSaleAmountsForDraft(amounts, leavesOutItems: false), amounts)
        XCTAssertNil(importedSaleAmountsForDraft(amounts, leavesOutItems: true), "no shipping either, so nothing is kept")
        amounts.shipping = 3
        let kept = importedSaleAmountsForDraft(amounts, leavesOutItems: true)
        XCTAssertEqual(kept?.notes, [importedSaleLeftOutNote, "Enter the shipping charged: y"])
    }

    // MARK: Unconfirmed-draft guard overflow

    func testAnEvictedAttemptKeepsTheGuardUntilAConfirmedCreation() {
        let date = Date(timeIntervalSince1970: 1_000)
        let timeout = URLError(.timedOut)
        let refused = APIError.http(status: 422, body: "{}", retryAfter: nil, rateLimitReset: nil)
        let full = (0..<unconfirmedDraftAttemptLimit).map { UnconfirmedDraftAttempt(recipient: "R\($0)", date: date) }
        let almost = Array(full.dropLast())
        XCTAssertFalse(unconfirmedDraftAttemptsOverflowed(previous: almost, overflowed: false, attempt: .failed(timeout)))
        XCTAssertTrue(unconfirmedDraftAttemptsOverflowed(previous: full, overflowed: false, attempt: .failed(timeout)),
                      "pushing out the oldest attempt sets the flag")
        XCTAssertTrue(unconfirmedDraftAttemptsOverflowed(previous: [], overflowed: true, attempt: .failed(timeout)))
        XCTAssertTrue(unconfirmedDraftAttemptsOverflowed(previous: full, overflowed: true, attempt: .failed(refused)),
                      "a definite refusal proves nothing about earlier attempts")
        XCTAssertFalse(unconfirmedDraftAttemptsOverflowed(previous: full, overflowed: false, attempt: .failed(refused)))
        XCTAssertTrue(unconfirmedDraftAttemptsOverflowed(previous: [], overflowed: true, attempt: .notSent))
        XCTAssertFalse(unconfirmedDraftAttemptsOverflowed(previous: full, overflowed: true, attempt: .succeeded),
                       "only a confirmed creation clears it")
    }

    func testNoticeAndCreateAnywayNameUnlistedAttempts() {
        let time: (Date) -> String = { _ in "2:32 PM" }
        let ada = UnconfirmedDraftAttempt(recipient: "Ada Lovelace", date: Date())
        let none = draftCreateUnknownNotice([], earlierUnlisted: true, time: time)
        XCTAssertEqual(none, "Earlier Create Draft attempts didn’t get a reply from Slant, so those drafts may exist. Check your drafts (Orders toolbar › Status › Draft) before creating them again.")
        let one = draftCreateUnknownNotice([ada], earlierUnlisted: true, time: time)
        XCTAssertTrue(one.hasPrefix("More than one Create Draft attempt didn’t get a reply from Slant (the latest: for Ada Lovelace at 2:32 PM)"))
        let five = (0..<unconfirmedDraftAttemptLimit).map { UnconfirmedDraftAttempt(recipient: "R\($0)", date: Date()) }
        XCTAssertTrue(draftCreateUnknownNotice(five, earlierUnlisted: true, time: time)
            .hasPrefix("More than 5 Create Draft attempts didn’t get a reply from Slant (the latest: for R0 at 2:32 PM; "))
        XCTAssertTrue(draftCreateAnywayMessage([ada], earlierUnlisted: true, time: time)
            .hasSuffix("If this is one of those orders, creating it again makes a second draft."))
        XCTAssertEqual(draftCreateUnknownNotice([ada], time: time), draftCreateUnknownNotice([ada], earlierUnlisted: false, time: time))

        // Look for Draft on Slant can't confirm an attempt that's no longer listed.
        var result = DraftMarkerSearchResult()
        let marked = UnconfirmedDraftAttempt(recipient: "Ada Lovelace", date: Date(), marker: "m1", platformID: "p")
        result.found = ["m1": Record(values: ["publicId": "SO-9", "id": "internal-1"])]
        result.ordersRead = 10
        let outcome = draftCreateCheckOutcome(attempts: [marked], result: result, earlierUnlisted: true, time: time)
        XCTAssertFalse(outcome.allConfirmed)
        XCTAssertTrue(outcome.message.contains("Earlier attempts that are no longer listed can’t be looked for."))
        XCTAssertTrue(outcome.message.contains("(order SO-9)"), "the order number, not an internal ID")
    }

    // MARK: Look for Draft on Slant

    func testButtonTitlesAndRowMapping() {
        XCTAssertEqual(draftCheckButtonTitle(count: 1), "Look for Draft on Slant")
        XCTAssertEqual(draftCheckButtonTitle(count: 3), "Look for Drafts on Slant")
        let order = OrderImportOrder(source: .etsy, sourceOrderID: " 3141 ")
        let other = OrderImportOrder(source: .shopify, sourceOrderID: "3141")
        let key = OrderImportLedger.key(source: .etsy, sourceOrderID: "3141")
        XCTAssertEqual(orderImportRowIDs(forLedgerKey: key, in: [order, other]), [order.id])
        XCTAssertEqual(orderImportRowIDs(forLedgerKey: key, in: []), [])
    }

    // MARK: Import sheet sections

    func testSectionsOpenWhileTheyNeedInputUntilTheSellerChooses() {
        XCTAssertTrue(orderImportSectionExpanded(userChoice: nil, needsInput: true))
        XCTAssertFalse(orderImportSectionExpanded(userChoice: nil, needsInput: false))
        XCTAssertFalse(orderImportSectionExpanded(userChoice: false, needsInput: true), "closed by the seller stays closed")
        XCTAssertTrue(orderImportSectionExpanded(userChoice: true, needsInput: false))
        XCTAssertEqual(orderImportMatchProductsTitle(keys: 3, unchosen: 2), "Match products · 2 of 3 to choose")
        XCTAssertEqual(orderImportMatchProductsTitle(keys: 3, unchosen: 0), "Match products · all chosen")
        XCTAssertEqual(batchPersonaliseSectionTitle(openSCADInstalled: false, products: 2, undecided: 2),
                       "Personalise with OpenSCAD · OpenSCAD isn’t installed")
        XCTAssertEqual(batchPersonaliseSectionTitle(openSCADInstalled: true, products: 2, undecided: 2), "Personalise with OpenSCAD · none chosen")
        XCTAssertEqual(batchPersonaliseSectionTitle(openSCADInstalled: true, products: 3, undecided: 1), "Personalise with OpenSCAD · 2 of 3 chosen")
        XCTAssertEqual(batchPersonaliseSectionTitle(openSCADInstalled: true, products: 1, undecided: 0), "Personalise with OpenSCAD · all chosen")
    }

    // MARK: Paste Address

    func testANameEndingInAStreetWordAboveANumberedStreet() {
        let parsed = parsePastedAddress("Damon Hill\n12 Main St\nSpringfield IL 62701\nUSA")
        XCTAssertEqual(parsed.name, "Damon Hill")
        XCTAssertEqual(parsed.line1, "12 Main St")
        XCTAssertEqual(parsed.unused, [])
        XCTAssertEqual(parsePastedAddress("Grace Hill\nPO Box 12\nSpringfield IL 62701").name, "Grace Hill")
        XCTAssertEqual(parsePastedAddress("Damon Hill\nc/o Williams\n12 Main St\nSpringfield IL 62701").name, "Damon Hill")
        // A street without a number before the town is still the street.
        let street = parsePastedAddress("High Street\nLondon\nSW1A 1AA")
        XCTAssertEqual(street.name, "")
        XCTAssertEqual(street.line1, "High Street")
        XCTAssertFalse(addressPasteFirstLineIsName("Mill Lane", following: ["Apt 4"]), "a unit line isn't a street")
        XCTAssertTrue(addressPasteFirstLineIsName("Mill Lane", following: ["Flat 2, 10 High St"]))
        XCTAssertFalse(addressPasteFirstLineIsName("c/o Jane", following: ["12 Main St"]))
        XCTAssertFalse(addressPasteFirstLineIsName("PO Box", following: ["12 Main St"]))
    }

    func testLinesBetweenTheNameAndTheStreetGoInLineTwo() {
        let careOf = parsePastedAddress("Ada Lovelace\nAcme Ltd\nc/o Jane Doe\n12 Main St\nApt 4\nSpringfield, IL 62701\nUnited States")
        XCTAssertEqual(careOf.name, "Ada Lovelace")
        XCTAssertEqual(careOf.line1, "12 Main St")
        XCTAssertEqual(careOf.line2, "c/o Jane Doe, Acme Ltd, Apt 4", "c/o first, then the company, then the unit")
        XCTAssertEqual(careOf.unused, [])
        let attn = parsePastedAddress("Ada Lovelace\nAttn: Accounts\nRose Cottage\n12 Main St, Apt 4\nLondon\nSW1A 1AA\nUnited Kingdom")
        XCTAssertEqual(attn.line1, "12 Main St")
        XCTAssertEqual(attn.line2, "Attn: Accounts, Rose Cottage, Apt 4")
        XCTAssertEqual(attn.city, "London")
        XCTAssertEqual(attn.zip, "SW1A 1AA")
        // A c/o line with digits is never taken as the street.
        let digits = parsePastedAddress("Ada Lovelace\nc/o 3D Prints Ltd\n12 Main St\nSpringfield, IL 62701")
        XCTAssertEqual(digits.line1, "12 Main St")
        XCTAssertEqual(digits.line2, "c/o 3D Prints Ltd")
        XCTAssertTrue(addressPasteIsCareOf("C/O Jane"))
        XCTAssertTrue(addressPasteIsCareOf("ATTN Jane"))
        XCTAssertTrue(addressPasteIsCareOf("FAO: Jane"))
        XCTAssertFalse(addressPasteIsCareOf("Faolan Byrne"))
        XCTAssertFalse(addressPasteIsCareOf("Attenborough House"))
    }

    func testPhoneWordsWithoutAColonArePhoneLines() {
        XCTAssertTrue(addressPasteIsPhone("Phone (555) 123-4567"))
        XCTAssertTrue(addressPasteIsPhone("Tel 555 0100"))
        XCTAssertTrue(addressPasteIsPhone("Tel. 12345"))
        XCTAssertTrue(addressPasteIsPhone("Mobile 07700 900123"))
        XCTAssertTrue(addressPasteIsPhone("Phone number +44 20 7946 0958"))
        XCTAssertTrue(addressPasteIsPhone("Cell phone 555-123-4567"))
        XCTAssertTrue(addressPasteIsPhone("Phone #: 555 123 4567"))
        XCTAssertFalse(addressPasteIsPhone("Mobile, AL 36602"), "Mobile is also a city")
        XCTAssertFalse(addressPasteIsPhone("Mobile AL 36602"))
        XCTAssertFalse(addressPasteIsPhone("Mobile 36602"))
        XCTAssertFalse(addressPasteIsPhone("Tel Aviv 6100000"))
        XCTAssertFalse(addressPasteIsPhone("Telford TF1 1AA"))
        XCTAssertFalse(addressPasteIsPhone("Phoenix AZ 85001"))
        XCTAssertFalse(addressPasteIsPhone("PH 301"), "A penthouse unit, not a phone line")
        XCTAssertTrue(addressPasteIsPhone("Ph 555 123 4567"))

        let parsed = parsePastedAddress("Ada Lovelace\n12 Main St\nSpringfield IL 62701\nUnited States\nPhone (555) 123-4567")
        XCTAssertEqual(parsed.zip, "62701", "the number is never read as a postcode")
        XCTAssertEqual(parsed.countryCode, "US")
        XCTAssertEqual(parsed.unused, [])
        let tel = parsePastedAddress("Ada Lovelace\n12 Main St\nSpringfield IL 62701\nTel 555 123 4567")
        XCTAssertEqual(tel.zip, "62701")
        let mobile = parsePastedAddress("Ada Lovelace\n1 Dauphin St\nMobile, AL 36602")
        XCTAssertEqual(mobile.city, "Mobile")
        XCTAssertEqual(mobile.state, "AL")
        XCTAssertEqual(mobile.zip, "36602")
    }

    func testAPasteWithoutACountryKeepsTheFormsCountry() {
        var current = deliveryApplyingCountryPick("GB", to: DeliveryDetails())
        current.name = "Typed Name"
        var pasted = PastedAddress()
        pasted.line1 = "1 High St"
        pasted.city = "London"
        XCTAssertEqual(orderCountryPickerValue(deliveryDetails(applyingPasted: pasted, to: current)), "GB")
        XCTAssertEqual(pastedAddressCountryDisplay(pasted, current: current), .keptFromForm("GB"))
        XCTAssertFalse(pastedAddressNeedsConfirmation(current: current, replacement: deliveryDetails(applyingPasted: pasted, to: current),
                                                      countryPicked: true), "a kept country isn't a change")
        let empty = deliveryApplyingCountryPick("", to: DeliveryDetails())
        XCTAssertEqual(pastedAddressCountryDisplay(pasted, current: empty), .missing)
        pasted.unrecognisedCountry = "Atlantis"
        XCTAssertEqual(pastedAddressCountryDisplay(pasted, current: current), .unrecognised("Atlantis"))
        pasted.unrecognisedCountry = ""
        pasted.countryCode = "US"
        XCTAssertEqual(pastedAddressCountryDisplay(pasted, current: current), .pasted("US"))
        XCTAssertTrue(pastedAddressNeedsConfirmation(current: current, replacement: deliveryDetails(applyingPasted: pasted, to: current),
                                                     countryPicked: true), "a pasted country replacing a picked one still asks")
    }

    func testReplaceWarningSaysWhatIsKept() {
        var current = DeliveryDetails()
        current.name = "Typed Name"
        var pasted = PastedAddress()
        pasted.line1 = "1 High St"
        XCTAssertEqual(pastedAddressReplaceWarning(pasted, current: current),
                       "This replaces delivery details already in the form. No name was found, so the current name is kept.")
        current.email = "a@example.com"
        XCTAssertTrue(pastedAddressReplaceWarning(pasted, current: current).hasSuffix("the current name and email are kept."))
        pasted.name = "Ada"
        pasted.email = "ada@example.com"
        XCTAssertEqual(pastedAddressReplaceWarning(pasted, current: current), "This replaces delivery details already in the form.")
        XCTAssertEqual(pastedAddressReplaceWarning(PastedAddress(), current: DeliveryDetails()),
                       "This replaces delivery details already in the form.")
    }

    // MARK: Spending Report

    private func printItem(price: Any, quantity: Int = 1) -> [String: Any] {
        ["type": "PRINT", "currency": "USD", "quantity": quantity, "price": price, "publicFileServiceId": "f1"]
    }

    func testPricesFromJSONDoublesAreComparedToTheCent() throws {
        // JSON doubles: 0.1 + 0.2 isn't exactly 0.3 in binary.
        let lines = spendReportPricedPrintLines([printItem(price: NSNumber(value: 0.1)), printItem(price: NSNumber(value: 0.2))],
                                                printingCost: NSNumber(value: 0.3))
        XCTAssertEqual(lines?.count, 2)
        // A value a double can't hold exactly, as Slant's JSON can arrive.
        let parsed = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(#"{"printingCost": 19.86, "items": [{"price": 9.93}, {"price": 9.93}]}"#.utf8)) as? [String: Any])
        let prices = try XCTUnwrap(parsed["items"] as? [[String: Any]]).map { $0["price"] as Any }
        let fromJSON = spendReportPricedPrintLines(prices.map { printItem(price: $0) }, printingCost: parsed["printingCost"])
        XCTAssertEqual(fromJSON?.map(\.price), [dec("9.93"), dec("9.93")])
        let imprecise = spendReportPricedPrintLines([printItem(price: NSDecimalNumber(string: "9.929999999999999"))],
                                                    printingCost: NSDecimalNumber(string: "9.93"))
        XCTAssertEqual(imprecise?.first?.price, dec("9.93"))
        // A real difference of a cent still leaves the order out.
        XCTAssertNil(spendReportPricedPrintLines([printItem(price: NSNumber(value: 9.92))], printingCost: NSNumber(value: 9.93)))
    }

    func testLoadingIsBlockedWhileBusy() {
        XCTAssertNotNil(spendReportPeriodLoadBlockedReason(hasKey: true, connected: true, busy: true, running: false))
        XCTAssertNil(spendReportPeriodLoadBlockedReason(hasKey: true, connected: true, busy: false, running: false))
    }
}
