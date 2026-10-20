import Foundation
import CoreLocation
import Contacts
import Combine

struct DeliveryAddressSuggestion: Equatable {
    var street: String
    var city: String
    var state: String
    var postalCode: String
    var countryCode: String

    var summary: String {
        [street, city, state, postalCode, countryCode].filter { !$0.isEmpty }.joined(separator: ", ")
    }

    func applying(to delivery: DeliveryDetails) -> DeliveryDetails {
        var result = delivery
        result.line1 = street
        // An apartment at the old address must not carry over to another building.
        result.line2 = ""
        result.city = city
        result.state = state
        result.zip = postalCode
        let country = defaultDeliveryCountry(regionCode: countryCode)
        result.countrySelection = country.selection
        result.customCountry = country.customCode
        return result
    }
}

func deliveryLocationIsUsable(_ location: CLLocation, now: Date = Date()) -> Bool {
    // App thresholds for suggesting an address, not a guarantee of the correct building.
    location.horizontalAccuracy >= 0 && location.horizontalAccuracy <= 100 &&
        abs(location.timestamp.timeIntervalSince(now)) <= 60
}

func deliveryAddressSuggestion(_ address: CNPostalAddress) -> DeliveryAddressSuggestion? {
    let street = address.street.trimmingCharacters(in: .whitespacesAndNewlines)
    let country = defaultDeliveryCountry(regionCode: address.isoCountryCode)
    guard !street.isEmpty, !country.selection.isEmpty else { return nil }
    return DeliveryAddressSuggestion(
        street: street, city: address.city, state: address.state,
        postalCode: address.postalCode, countryCode: address.isoCountryCode.uppercased()
    )
}

/// Created with the form, but only accesses location after the user presses the button.
/// A fresh manager per attempt prevents cancelled requests from updating a later attempt.
/// Managers are created on the main thread, whose run loop delivers their delegate callbacks.
@MainActor
final class DeliveryLocationLookup: NSObject, ObservableObject, @preconcurrency CLLocationManagerDelegate {
    @Published private(set) var isBusy = false
    @Published private(set) var message: String?
    @Published private(set) var suggestion: DeliveryAddressSuggestion?
    private var manager: CLLocationManager?
    private var geocoder: CLGeocoder?
    private var timeout: Task<Void, Never>?
    private var attempt: UUID?
    private var locationRequested = false

    func start() {
        cancel()
        suggestion = nil
        message = nil
        // SwiftPM command-line runs don't include the permission purpose strings.
        guard Bundle.main.object(forInfoDictionaryKey: "NSLocationUsageDescription") != nil else {
            message = "Open the packaged Slant Studio app to use location, or enter your address manually."
            return
        }
        let token = UUID()
        attempt = token
        isBusy = true
        let manager = CLLocationManager()
        self.manager = manager
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        timeout = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(45)) } catch { return }
            guard let self, self.attempt == token else { return }
            self.fail("Location lookup timed out. Try again or enter your address manually.")
        }
        continueAfterAuthorization(manager)
    }

    func cancel() {
        attempt = nil
        timeout?.cancel()
        timeout = nil
        manager?.stopUpdatingLocation()
        manager?.delegate = nil
        manager = nil
        geocoder?.cancelGeocode()
        geocoder = nil
        locationRequested = false
        isBusy = false
    }

    func clearSuggestion() { suggestion = nil }

    private func fail(_ explanation: String) {
        cancel()
        message = explanation
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        guard self.manager === manager, isBusy else { return }
        continueAfterAuthorization(manager)
    }

    private func continueAfterAuthorization(_ manager: CLLocationManager) {
        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .authorizedAlways, .authorizedWhenInUse:
            guard !locationRequested else { return }
            locationRequested = true
            manager.requestLocation()
        case .denied, .restricted:
            fail("Location access is unavailable. Enter your address manually, or allow Slant Studio in System Settings → Privacy & Security → Location Services.")
        @unknown default:
            fail("Location is unavailable. Enter your address manually.")
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard self.manager === manager, let token = attempt, geocoder == nil else { return }
        guard let location = locations.last, deliveryLocationIsUsable(location) else {
            fail("Your location isn’t accurate enough to suggest a street address. Try again or enter it manually.")
            return
        }
        manager.stopUpdatingLocation()
        let geocoder = CLGeocoder()
        self.geocoder = geocoder
        geocoder.reverseGeocodeLocation(location) { [weak self] placemarks, error in
            Task { @MainActor in
                guard let self, self.attempt == token else { return }
                guard error == nil, let address = placemarks?.first?.postalAddress,
                      let suggestion = deliveryAddressSuggestion(address) else {
                    self.fail("We couldn’t find a street address here. Enter your delivery address manually.")
                    return
                }
                self.cancel()
                self.suggestion = suggestion
            }
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        guard self.manager === manager, isBusy else { return }
        fail("Couldn’t determine your location. Check Location Services and your connection, or enter your address manually.")
    }
}
