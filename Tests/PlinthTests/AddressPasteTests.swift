import XCTest
@testable import Plinth

final class AddressPasteTests: XCTestCase {
    // MARK: Real-world shapes

    func testEtsyUSBlockWithUnitZipPlusFourAndCountry() {
        let parsed = parsePastedAddress("""
        Ada Lovelace
        12 Main St
        Apt 4
        SPRINGFIELD, IL 62701-1234
        United States
        """)
        XCTAssertEqual(parsed.name, "Ada Lovelace")
        XCTAssertEqual(parsed.line1, "12 Main St")
        XCTAssertEqual(parsed.line2, "Apt 4")
        XCTAssertEqual(parsed.city, "SPRINGFIELD")
        XCTAssertEqual(parsed.state, "IL")
        XCTAssertEqual(parsed.zip, "62701-1234")
        XCTAssertEqual(parsed.countryCode, "US")
        XCTAssertEqual(parsed.email, "")
        XCTAssertEqual(parsed.unused, [])
        XCTAssertTrue(parsed.foundAddress)
    }

    func testShopifyBlockIgnoresPhoneAndListsCompanyAsNotUsed() {
        let parsed = parsePastedAddress("""
        Shipping address
        Ada Lovelace
        Acme Ltd
        12 Main St
        Springfield IL 62701
        United States
        +1 555-123-4567
        """)
        XCTAssertEqual(parsed.name, "Ada Lovelace")
        XCTAssertEqual(parsed.line1, "12 Main St")
        XCTAssertEqual(parsed.line2, "Acme Ltd", "A company between the name and the street goes in line 2")
        XCTAssertEqual(parsed.city, "Springfield")
        XCTAssertEqual(parsed.state, "IL")
        XCTAssertEqual(parsed.zip, "62701")
        XCTAssertEqual(parsed.countryCode, "US")
        XCTAssertEqual(parsed.unused, [])
    }

    func testFullStateNameAndUSAAlias() {
        let parsed = parsePastedAddress("Grace Hopper\n1 Navy Way\nArlington, Virginia 22201\nUSA")
        XCTAssertEqual(parsed.city, "Arlington")
        XCTAssertEqual(parsed.state, "Virginia")
        XCTAssertEqual(parsed.zip, "22201")
        XCTAssertEqual(parsed.countryCode, "US")
    }

    func testMultiWordCityBeforeStateAbbreviation() {
        let parsed = parsePastedAddress("Ada Lovelace\n350 5th Ave\nNew York NY 10118\nUnited States")
        XCTAssertEqual(parsed.line1, "350 5th Ave")
        XCTAssertEqual(parsed.city, "New York")
        XCTAssertEqual(parsed.state, "NY")
    }

    func testUKBlockWithFlatPostcodeOnItsOwnLine() {
        let parsed = parsePastedAddress("""
        Jane Smith
        Flat 2
        10 Downing Street
        London
        SW1A 2AA
        United Kingdom
        """)
        XCTAssertEqual(parsed.name, "Jane Smith")
        XCTAssertEqual(parsed.line1, "10 Downing Street")
        XCTAssertEqual(parsed.line2, "Flat 2")
        XCTAssertEqual(parsed.city, "London")
        XCTAssertEqual(parsed.state, "")
        XCTAssertEqual(parsed.zip, "SW1A 2AA")
        XCTAssertEqual(parsed.countryCode, "GB")
    }

    func testUKBlockWithLocalityAndCounty() {
        let parsed = parsePastedAddress("""
        Jane Smith
        1 High Street
        Little Village
        Cambridge
        Cambridgeshire
        CB1 1AA
        UK
        """)
        XCTAssertEqual(parsed.line1, "1 High Street")
        XCTAssertEqual(parsed.line2, "Little Village")
        XCTAssertEqual(parsed.city, "Cambridge")
        XCTAssertEqual(parsed.state, "Cambridgeshire")
        XCTAssertEqual(parsed.zip, "CB1 1AA")
        XCTAssertEqual(parsed.countryCode, "GB")
    }

    func testUKTownAndPostcodeOnOneLineAndEnglandAlias() {
        let parsed = parsePastedAddress("J Smith\nFlat 3, 22 Baker Street\nLondon NW1 6XE\nEngland")
        XCTAssertEqual(parsed.line1, "22 Baker Street")
        XCTAssertEqual(parsed.line2, "Flat 3")
        XCTAssertEqual(parsed.city, "London")
        XCTAssertEqual(parsed.zip, "NW1 6XE")
        XCTAssertEqual(parsed.countryCode, "GB")
    }

    func testCanada() {
        let parsed = parsePastedAddress("Jean Tremblay\n100 Queen St W\nToronto ON M5H 2N2\nCanada")
        XCTAssertEqual(parsed.line1, "100 Queen St W")
        XCTAssertEqual(parsed.city, "Toronto")
        XCTAssertEqual(parsed.state, "ON")
        XCTAssertEqual(parsed.zip, "M5H 2N2")
        XCTAssertEqual(parsed.countryCode, "CA")
    }

    func testCanadaWithProvinceName() {
        let parsed = parsePastedAddress("Jean Tremblay\n1 Rue Sainte-Catherine\nMontréal, Quebec H2X 1Z4\nCanada")
        XCTAssertEqual(parsed.city, "Montréal")
        XCTAssertEqual(parsed.state, "Quebec")
        XCTAssertEqual(parsed.zip, "H2X 1Z4")
    }

    func testAustraliaWithUnitBeforeStreet() {
        let parsed = parsePastedAddress("Sam Citizen\nUnit 5, 20 George St\nSYDNEY NSW 2000\nAustralia")
        XCTAssertEqual(parsed.name, "Sam Citizen")
        XCTAssertEqual(parsed.line1, "20 George St")
        XCTAssertEqual(parsed.line2, "Unit 5")
        XCTAssertEqual(parsed.city, "SYDNEY")
        XCTAssertEqual(parsed.state, "NSW")
        XCTAssertEqual(parsed.zip, "2000")
        XCTAssertEqual(parsed.countryCode, "AU")
    }

    func testGermanyAndNetherlandsPostcodeBeforeTown() {
        let germany = parsePastedAddress("Max Mustermann\nMusterstraße 5\n10115 Berlin\nGermany")
        XCTAssertEqual(germany.name, "Max Mustermann")
        XCTAssertEqual(germany.line1, "Musterstraße 5")
        XCTAssertEqual(germany.zip, "10115")
        XCTAssertEqual(germany.city, "Berlin")
        XCTAssertEqual(germany.countryCode, "DE")
        let dutch = parsePastedAddress("Anne de Vries\nDamrak 1\n1012 AB Amsterdam\nNetherlands")
        XCTAssertEqual(dutch.zip, "1012 AB")
        XCTAssertEqual(dutch.city, "Amsterdam")
        XCTAssertEqual(dutch.countryCode, "NL")
    }

    func testIrelandEircodeAndDistrictNumber() {
        let parsed = parsePastedAddress("Seán Murphy\n1 Main Street\nDublin 2\nD02 X285\nIreland")
        XCTAssertEqual(parsed.city, "Dublin 2")
        XCTAssertEqual(parsed.zip, "D02 X285")
        XCTAssertEqual(parsed.countryCode, "IE")
    }

    func testOneLineCommaSeparated() {
        let parsed = parsePastedAddress("Ada Lovelace, 12 Main St, Apt 4, Springfield, IL 62701, USA")
        XCTAssertEqual(parsed.name, "Ada Lovelace")
        XCTAssertEqual(parsed.line1, "12 Main St")
        XCTAssertEqual(parsed.line2, "Apt 4")
        XCTAssertEqual(parsed.city, "Springfield")
        XCTAssertEqual(parsed.state, "IL")
        XCTAssertEqual(parsed.zip, "62701")
        XCTAssertEqual(parsed.countryCode, "US")
    }

    func testOneLineCommaSeparatedUKWithoutName() {
        let parsed = parsePastedAddress("10 Downing Street, London, SW1A 2AA, United Kingdom")
        XCTAssertEqual(parsed.name, "")
        XCTAssertEqual(parsed.line1, "10 Downing Street")
        XCTAssertEqual(parsed.city, "London")
        XCTAssertEqual(parsed.zip, "SW1A 2AA")
        XCTAssertEqual(parsed.countryCode, "GB")
    }

    func testOnlyATownBeforeThePostcode() {
        let us = parsePastedAddress("Springfield, IL 62701")
        XCTAssertEqual(us.name, "")
        XCTAssertEqual(us.city, "Springfield")
        XCTAssertEqual(us.state, "IL")
        let uk = parsePastedAddress("London, SW1A 1AA")
        XCTAssertEqual(uk.name, "")
        XCTAssertEqual(uk.city, "London")
        XCTAssertEqual(uk.zip, "SW1A 1AA")
    }

    func testOneLineWithoutCommasSplitsStreetFromCity() {
        let parsed = parsePastedAddress("12 Main St Springfield IL 62701")
        XCTAssertEqual(parsed.line1, "12 Main St")
        XCTAssertEqual(parsed.city, "Springfield")
        XCTAssertEqual(parsed.state, "IL")
        XCTAssertEqual(parsed.zip, "62701")
        XCTAssertEqual(parsed.countryCode, "", "No country written, so none is assumed")
    }

    func testTrailingUnitOnTheStreetLineIsSplitOff() {
        let parsed = parsePastedAddress("Ada Lovelace\n12 Main St, Suite 200\nAustin, TX 78701\nUnited States")
        XCTAssertEqual(parsed.line1, "12 Main St")
        XCTAssertEqual(parsed.line2, "Suite 200")
        // A street name that only starts like a unit word stays whole.
        XCTAssertEqual(addressPasteSplittingUnit("12 Flat Rock Rd").street, "12 Flat Rock Rd")
        XCTAssertNil(addressPasteSplittingUnit("12 Flat Rock Rd").unit)
        XCTAssertFalse(addressPasteIsUnit("Unity Lane"))
        XCTAssertTrue(addressPasteIsUnit("#12"))
        XCTAssertTrue(addressPasteIsUnit("Unit B"))
    }

    func testEmailAnywhereIsTakenAndItsLineCleaned() {
        let parsed = parsePastedAddress("""
        Ada Lovelace <ada@example.com>
        12 Main St
        Springfield, IL 62701
        United States
        Phone: (555) 123-4567
        """)
        XCTAssertEqual(parsed.name, "Ada Lovelace")
        XCTAssertEqual(parsed.email, "ada@example.com")
        XCTAssertEqual(parsed.unused, [])
        let labelled = parsePastedAddress("Ada Lovelace\n12 Main St\nSpringfield, IL 62701\nEmail: ada@example.com")
        XCTAssertEqual(labelled.email, "ada@example.com")
        XCTAssertEqual(labelled.unused, [])
    }

    func testNoEmailIsInvented() {
        let parsed = parsePastedAddress("Ada Lovelace\n12 Main St\nSpringfield, IL 62701")
        XCTAssertEqual(parsed.email, "")
        let broken = parsePastedAddress("Ada Lovelace\nada@localhost\n12 Main St\nSpringfield, IL 62701")
        XCTAssertEqual(broken.email, "", "Only a complete address like name@example.com is used")
    }

    func testLabelledForm() {
        let parsed = parsePastedAddress("""
        Name: Ada Lovelace
        Address: 12 Main St
        Address line 2: Apt 4
        City: Springfield
        State: IL
        ZIP code: 62701
        Country: US
        Phone: 555-123-4567
        """)
        XCTAssertEqual(parsed.name, "Ada Lovelace")
        XCTAssertEqual(parsed.line1, "12 Main St")
        XCTAssertEqual(parsed.line2, "Apt 4")
        XCTAssertEqual(parsed.city, "Springfield")
        XCTAssertEqual(parsed.state, "IL")
        XCTAssertEqual(parsed.zip, "62701")
        XCTAssertEqual(parsed.countryCode, "US")
    }

    // MARK: Countries are never assumed

    func testMissingCountryIsLeftUnselected() {
        let parsed = parsePastedAddress("Ada Lovelace\n12 Main St\nSpringfield, IL 62701")
        XCTAssertEqual(parsed.countryCode, "")
        XCTAssertEqual(parsed.unrecognisedCountry, "")
    }

    func testUnrecognisedCountryIsReportedNotGuessed() {
        let parsed = parsePastedAddress("Ada Lovelace\n12 Main St\nSpringfield, IL 62701\nAtlantis")
        XCTAssertEqual(parsed.countryCode, "")
        XCTAssertEqual(parsed.unrecognisedCountry, "Atlantis")
    }

    func testBareTwoLetterCodeIsACountryOnlyAfterThePostcode() {
        XCTAssertEqual(parsePastedAddress("Ada Lovelace\n12 Main St\nSpringfield, IL 62701\nUS").countryCode, "US")
        // "IL" before the ZIP is the state, never Israel.
        let parsed = parsePastedAddress("12 Main St, Springfield, IL 62701")
        XCTAssertEqual(parsed.state, "IL")
        XCTAssertEqual(parsed.countryCode, "")
        XCTAssertEqual(addressPasteCountryCode("IL", allowBareCode: false), "")
        XCTAssertEqual(addressPasteCountryCode("Scotland", allowBareCode: false), "GB")
        XCTAssertEqual(addressPasteCountryCode("EU", allowBareCode: true), "", "Not a delivery country")
    }

    // MARK: Postcodes are kept as written

    func testZipPlusFourOnItsOwnLineIsNotAPhoneNumber() {
        let parsed = parsePastedAddress("Ada Lovelace\n12 Main St\nSpringfield\nIL\n62701-1234\nUnited States\n555-123-4567")
        XCTAssertEqual(parsed.zip, "62701-1234")
        XCTAssertEqual(parsed.city, "Springfield")
        XCTAssertEqual(parsed.state, "IL")
        XCTAssertEqual(parsed.unused, [])
        XCTAssertTrue(addressPasteIsPhone("Tel: +44 20 7946 0958"))
        XCTAssertFalse(addressPasteIsPhone("62701"))
    }

    func testZipIsNeverPadded() {
        let parsed = parsePastedAddress("Ada Lovelace\n1 Beacon St\nBoston, MA 2108\nUnited States")
        XCTAssertEqual(parsed.zip, "2108")
        XCTAssertEqual(parsed.city, "Boston")
        XCTAssertEqual(parsed.state, "MA")
    }

    // MARK: Junk

    func testJunkFindsNoAddress() {
        XCTAssertFalse(parsePastedAddress("").foundAddress)
        XCTAssertFalse(parsePastedAddress("   \n\n  ").foundAddress)
        XCTAssertFalse(parsePastedAddress("Thanks for your order! We’ll be in touch.").foundAddress)
        XCTAssertFalse(parsePastedAddress("+1 555 123 4567").foundAddress)
        XCTAssertFalse(parsePastedAddress("ada@example.com").foundAddress)
        let reference = parsePastedAddress("Order #1234")
        XCTAssertEqual(reference.zip, "", "A reference number isn't a postcode")
        XCTAssertEqual(reference.city, "")
    }

    func testHugeInputIsBounded() {
        let huge = String(repeating: "Ada Lovelace, 12 Main St, Springfield, IL 62701\n", count: 5_000)
        let start = Date()
        let parsed = parsePastedAddressDetecting(huge)
        XCTAssertLessThan(Date().timeIntervalSince(start), 5)
        XCTAssertLessThanOrEqual(addressPasteLines(huge).count, addressPasteMaxItems)
        XCTAssertTrue(parsed.foundAddress)
        let oneLong = String(repeating: "x", count: 50_000)
        XCTAssertFalse(parsePastedAddressDetecting(oneLong).foundAddress)
    }

    // MARK: Detector fallback (pure merge)

    func testDetectedPartsFillOnlyWhatTheRulesLeftEmpty() {
        let nothing = PastedAddress(name: "Ada Lovelace")
        let detected = DetectedAddressParts(street: "12 Main St", city: "Springfield", state: "IL", zip: "62701", country: "Atlantis")
        let merged = pastedAddress(nothing, fillingFrom: detected)
        XCTAssertEqual(merged.name, "Ada Lovelace")
        XCTAssertEqual(merged.line1, "12 Main St")
        XCTAssertEqual(merged.city, "Springfield")
        XCTAssertEqual(merged.zip, "62701")
        XCTAssertEqual(merged.countryCode, "", "An unrecognised detected country is ignored")
        var partial = PastedAddress()
        partial.zip = "SW1A 2AA"
        let kept = pastedAddress(partial, fillingFrom: DetectedAddressParts(zip: "99999", country: "United Kingdom"))
        XCTAssertEqual(kept.zip, "SW1A 2AA")
        XCTAssertEqual(kept.countryCode, "GB")
        XCTAssertEqual(pastedAddress(partial, fillingFrom: nil), partial)
    }

    // MARK: Applying and confirmation

    func testApplyingReplacesTheAddressClearsTheOldUnitAndKeepsMissingNameAndEmail() {
        var current = DeliveryDetails()
        current.name = "Typed Name"
        current.email = "typed@example.com"
        current.line1 = "Old Street 1"
        current.line2 = "Apt 9"
        current.city = "Oldtown"
        current = deliveryApplyingCountryPick("GB", to: current)
        var pasted = PastedAddress()
        pasted.line1 = "12 Main St"
        pasted.city = "Springfield"
        pasted.state = "IL"
        pasted.zip = "62701"
        pasted.countryCode = "US"
        let applied = deliveryDetails(applyingPasted: pasted, to: current)
        XCTAssertEqual(applied.name, "Typed Name")
        XCTAssertEqual(applied.email, "typed@example.com")
        XCTAssertEqual(applied.line1, "12 Main St")
        XCTAssertEqual(applied.line2, "", "The old apartment never carries over")
        XCTAssertEqual(orderCountryPickerValue(applied), "US")
        pasted.name = "Ada Lovelace"
        pasted.email = "ada@example.com"
        pasted.countryCode = ""
        let replaced = deliveryDetails(applyingPasted: pasted, to: current)
        XCTAssertEqual(replaced.name, "Ada Lovelace")
        XCTAssertEqual(replaced.email, "ada@example.com")
        XCTAssertEqual(orderCountryPickerValue(replaced), "GB", "No country in the paste keeps the form's")
        pasted.unrecognisedCountry = "Atlantis"
        XCTAssertEqual(orderCountryPickerValue(deliveryDetails(applyingPasted: pasted, to: current)), "",
                       "An unrecognised country leaves it for the seller to choose")
        pasted.unrecognisedCountry = ""
        pasted.countryCode = "NZ"
        XCTAssertEqual(orderCountryPickerValue(deliveryDetails(applyingPasted: pasted, to: current)), "NZ")
    }

    func testConfirmationOnlyWhenSomethingEnteredWouldChange() {
        var pasted = PastedAddress()
        pasted.line1 = "12 Main St"
        pasted.city = "Springfield"
        pasted.zip = "62701"
        pasted.countryCode = "US"
        let blank = DeliveryDetails()
        XCTAssertFalse(pastedAddressNeedsConfirmation(current: blank, replacement: deliveryDetails(applyingPasted: pasted, to: blank),
                                                      countryPicked: false), "An empty form (region default only) is filled at once")
        var named = DeliveryDetails()
        named.name = "Ada Lovelace"
        XCTAssertFalse(pastedAddressNeedsConfirmation(current: named, replacement: deliveryDetails(applyingPasted: pasted, to: named),
                                                      countryPicked: false), "A kept name isn't replaced")
        var withUnit = named
        withUnit.line2 = "Apt 9"
        XCTAssertTrue(pastedAddressNeedsConfirmation(current: withUnit, replacement: deliveryDetails(applyingPasted: pasted, to: withUnit),
                                                     countryPicked: false))
        let picked = deliveryApplyingCountryPick("GB", to: DeliveryDetails())
        XCTAssertTrue(pastedAddressNeedsConfirmation(current: picked, replacement: deliveryDetails(applyingPasted: pasted, to: picked),
                                                     countryPicked: true), "A picked country counts")
        XCTAssertFalse(pastedAddressNeedsConfirmation(current: picked, replacement: deliveryDetails(applyingPasted: pasted, to: picked),
                                                      countryPicked: false), "The region default doesn't")
    }

    // MARK: Pasteboard prefill

    func testPrefillOnlyForAddressSizedPlainText() {
        XCTAssertEqual(addressPastePrefill(nil), "")
        XCTAssertEqual(addressPastePrefill("   \n"), "")
        XCTAssertEqual(addressPastePrefill("Ada Lovelace\n12 Main St"), "Ada Lovelace\n12 Main St")
        XCTAssertEqual(addressPastePrefill("/Users/me/file.stl", holdsFileURL: true), "")
        XCTAssertEqual(addressPastePrefill(String(repeating: "a", count: addressPasteMaxCharacters + 1)), "")
    }
}
