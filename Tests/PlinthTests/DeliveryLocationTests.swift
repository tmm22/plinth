import XCTest
import CoreLocation
import Contacts
@testable import Plinth

final class DeliveryLocationTests: XCTestCase {
    func testSuggestionMapsInternationalAddressAndPreservesContactDetails() throws {
        let address = CNMutablePostalAddress()
        address.street = " 12 Example Street "
        address.city = "Brisbane"
        address.state = "QLD"
        address.postalCode = "4000"
        address.isoCountryCode = "au"
        let suggestion = try XCTUnwrap(deliveryAddressSuggestion(address))
        let previous = DeliveryDetails(email: "person@example.com", name: "Person", line1: "Old road", line2: "Unit 99", city: "Old city", state: "Old state", zip: "12345", countrySelection: "US")
        let result = suggestion.applying(to: previous)
        XCTAssertEqual(result.name, previous.name)
        XCTAssertEqual(result.email, previous.email)
        XCTAssertEqual(result.line1, "12 Example Street")
        XCTAssertEqual(result.line2, "")
        XCTAssertEqual(result.city, "Brisbane")
        XCTAssertEqual(result.state, "QLD")
        XCTAssertEqual(result.zip, "4000")
        XCTAssertEqual(result.countrySelection, "AU")
        XCTAssertEqual(previous.line1, "Old road")
    }

    func testPartialAddressDoesNotMixWithPreviousDestination() throws {
        let address = CNMutablePostalAddress()
        address.street = "Example street"
        address.isoCountryCode = "SE"
        let suggestion = try XCTUnwrap(deliveryAddressSuggestion(address))
        let result = suggestion.applying(to: DeliveryDetails(city: "Old city", state: "Old state", zip: "12345"))
        XCTAssertEqual(result.city, "")
        XCTAssertEqual(result.state, "")
        XCTAssertEqual(result.zip, "")
        XCTAssertEqual(result.countrySelection, orderCountryOtherTag)
        XCTAssertEqual(result.customCountry, "SE")
    }

    func testNonStreetAndUnknownCountryResultsAreNotOffered() {
        let address = CNMutablePostalAddress()
        address.city = "Brisbane"
        address.isoCountryCode = "AU"
        XCTAssertNil(deliveryAddressSuggestion(address))
        address.street = "Example street"
        address.isoCountryCode = ""
        XCTAssertNil(deliveryAddressSuggestion(address))
    }

    func testStaleAndImpreciseLocationsAreRejected() {
        let now = Date()
        func location(accuracy: Double, age: TimeInterval = 0) -> CLLocation {
            CLLocation(coordinate: CLLocationCoordinate2D(latitude: 0, longitude: 0), altitude: 0, horizontalAccuracy: accuracy, verticalAccuracy: -1, timestamp: now.addingTimeInterval(-age))
        }
        XCTAssertTrue(deliveryLocationIsUsable(location(accuracy: 10), now: now))
        XCTAssertFalse(deliveryLocationIsUsable(location(accuracy: -1), now: now))
        XCTAssertFalse(deliveryLocationIsUsable(location(accuracy: 2000), now: now))
        XCTAssertFalse(deliveryLocationIsUsable(location(accuracy: 10, age: 120), now: now))
    }

    @MainActor
    func testLookupStartsIdleAndIgnoresUnrelatedCallbacks() {
        let lookup = DeliveryLocationLookup()
        XCTAssertFalse(lookup.isBusy)
        XCTAssertNil(lookup.suggestion)
        XCTAssertNil(lookup.message)
        lookup.cancel()
        let manager = CLLocationManager()
        lookup.locationManager(manager, didFailWithError: NSError(domain: kCLErrorDomain, code: CLError.denied.rawValue))
        lookup.locationManager(manager, didUpdateLocations: [CLLocation(latitude: 0, longitude: 0)])
        XCTAssertFalse(lookup.isBusy)
        XCTAssertNil(lookup.suggestion)
        XCTAssertNil(lookup.message)
    }
}
