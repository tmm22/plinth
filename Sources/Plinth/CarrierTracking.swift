import Foundation

// MARK: - Carrier from a tracking number
//
// Works out the carrier from a tracking number's own pattern and check digit, locally: nothing is sent anywhere, and
// the tracking page is opened only when the seller clicks Track Parcel. A carrier is named only for a match that is
// checksum-valid and unambiguous; anything else is "not recognised" and nothing is shown. Slant's `fulfillment.provider`
// names the label service (SHIPPO, SHIPSTATION), not the carrier, and Slant sends no tracking link (live, 1 Nov 2026).
//
// Rules checked against the MIT-licensed jkeen/tracking_number_data test numbers (UPS 1Z, USPS IMpb, FedEx Express 12
// and Ground 15, DHL Express 10, UPU S10) and UPU S10's published check digit; only the rules are reimplemented.

/// A carrier worked out from a tracking number.
struct DetectedCarrier: Equatable, Sendable {
    /// The carrier's name for display ("USPS", "Royal Mail").
    let name: String
    /// The carrier's tracking page for this number (https, the number percent-encoded), or nil when Plinth knows no
    /// reliable page for it. Opened only on the seller's click.
    let trackingURL: URL?
    /// The exact name Shopify's tracking-company list uses for this carrier, or nil when Shopify doesn't list it.
    let shopifyCompany: String?
}

/// What a tracking number's pattern says about its carrier.
enum CarrierDetection: Equatable, Sendable {
    case recognised(DetectedCarrier)
    /// The pattern and check digit fit more than one carrier (such as USPS's 92 numbers, which FedEx Ground Economy
    /// and other services that hand parcels to USPS also print).
    case ambiguous([String])
    case notRecognised

    var carrier: DetectedCarrier? {
        if case .recognised(let carrier) = self { return carrier }
        return nil
    }
}

/// Longest tracking number considered.
let carrierTrackingNumberMaxLength = 40

/// The number as the rules read it: spaces removed and letters in capitals. Nil when empty, too long or holding
/// anything other than ASCII letters and digits (a hyphen, punctuation, another script).
func carrierTrackingNumberKey(_ raw: String) -> String? {
    let compact = raw.filter { !$0.isWhitespace }.uppercased()
    guard !compact.isEmpty, compact.count <= carrierTrackingNumberMaxLength,
          compact.unicodeScalars.allSatisfy({ ("A"..."Z").contains($0) || ("0"..."9").contains($0) }) else { return nil }
    return compact
}

/// The carrier for one tracking number, or `.notRecognised`.
func detectCarrier(_ raw: String) -> CarrierDetection {
    // An all-zero number passes several check digits but is a placeholder, never a parcel.
    guard let number = carrierTrackingNumberKey(raw), number.contains(where: { $0.isNumber && $0 != "0" }) else { return .notRecognised }
    var candidates: [DetectedCarrier] = []
    var ambiguousNames: [String] = []
    if let carrier = carrierFromS10(number) { candidates.append(carrier) }
    if carrierIsUPS(number) { candidates.append(carrierKnown(.ups, number: number)) }
    switch carrierUSPSIMpb(number) {
    case .usps: candidates.append(carrierKnown(.usps, number: number))
    case .shared: ambiguousNames += ["USPS", "FedEx Ground Economy"]
    case nil: break
    }
    if carrierIsFedEx12(number) || carrierIsFedEx15(number) { candidates.append(carrierKnown(.fedex, number: number)) }
    if carrierIsDHLExpress10(number) { candidates.append(carrierKnown(.dhlExpress, number: number)) }
    let names = Array(Set(candidates.map(\.name) + ambiguousNames)).sorted()
    if names.count > 1 || !ambiguousNames.isEmpty { return .ambiguous(names) }
    guard let only = candidates.first else { return .notRecognised }
    return .recognised(only)
}

/// The one carrier every number names, or nil when there are none, any isn't recognised, or they differ.
func detectCarrier(forNumbers numbers: [String]) -> DetectedCarrier? {
    let carriers = numbers.map { detectCarrier($0).carrier }
    guard let first = carriers.first ?? nil, carriers.allSatisfy({ $0?.name == first.name }) else { return nil }
    return first
}

// MARK: Label services

/// Label services Slant may report as `fulfillment.provider`, by their letters in capitals, with proper names. They
/// buy and print labels; they aren't the carrier.
let carrierLabelServiceNames: [String: String] = ["SHIPPO": "Shippo", "SHIPSTATION": "ShipStation", "EASYPOST": "EasyPost"]

/// The label service's proper name when `provider` is one ("SHIPPO" → "Shippo"), else nil.
func carrierLabelServiceName(_ provider: String?) -> String? {
    guard let provider else { return nil }
    return carrierLabelServiceNames[carrierNameKey(provider)]
}

/// Letters and digits in capitals: "FedEx" and "FEDEX" match, "DHL Express" is "DHLEXPRESS".
func carrierNameKey(_ name: String) -> String {
    String(name.uppercased().unicodeScalars.filter { ("A"..."Z").contains($0) || ("0"..."9").contains($0) }.map(Character.init))
}

/// Other spellings a service may use for a carrier Plinth detects.
private let carrierNameAliases: [String: String] = [
    "DHL": "DHLEXPRESS", "USPSINTERNATIONAL": "USPS", "UNITEDSTATESPOSTALSERVICE": "USPS", "FEDERALEXPRESS": "FEDEX",
    "UNITEDPARCELSERVICE": "UPS", "FEDEXEXPRESS": "FEDEX", "FEDEXGROUND": "FEDEX"
]

/// Whether a carrier a service named and a detected one are the same carrier.
func carrierNamesAgree(_ named: String, _ detected: String) -> Bool {
    let left = carrierNameKey(named), right = carrierNameKey(detected)
    guard !left.isEmpty, !right.isEmpty else { return false }
    return (carrierNameAliases[left] ?? left) == (carrierNameAliases[right] ?? right)
}

/// The detected carrier to show and link for a number, given the carrier the service named (Slant's provider or
/// 3DAPI's carrier). A label service or no name leaves the detection as it is; a real carrier name keeps it only when
/// they agree, so Plinth never links to a different carrier than the one the service named.
func carrierDetected(forNumber number: String, namedCarrier: String?) -> DetectedCarrier? {
    guard let carrier = detectCarrier(number).carrier else { return nil }
    let named = namedCarrier?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    if named.isEmpty || carrierLabelServiceName(named) != nil { return carrier }
    return carrierNamesAgree(named, carrier.name) ? carrier : nil
}

/// The same for every number of an order: nil unless each number detects the same carrier under that rule.
func carrierDetected(forNumbers numbers: [String], namedCarrier: String?) -> DetectedCarrier? {
    let carriers = numbers.map { carrierDetected(forNumber: $0, namedCarrier: namedCarrier) }
    guard let first = carriers.first ?? nil, carriers.allSatisfy({ $0?.name == first.name }) else { return nil }
    return first
}

// MARK: Carriers

private enum KnownCarrier {
    case usps, ups, fedex, dhlExpress
}

private func carrierKnown(_ carrier: KnownCarrier, number: String) -> DetectedCarrier {
    switch carrier {
    case .usps:
        return DetectedCarrier(name: "USPS", trackingURL: carrierURL("https://tools.usps.com/go/TrackConfirmAction?tLabels=", number),
                               shopifyCompany: "USPS")
    case .ups:
        return DetectedCarrier(name: "UPS", trackingURL: carrierURL("https://www.ups.com/track?tracknum=", number), shopifyCompany: "UPS")
    case .fedex:
        return DetectedCarrier(name: "FedEx", trackingURL: carrierURL("https://www.fedex.com/fedextrack/?trknbr=", number),
                               shopifyCompany: "FedEx")
    case .dhlExpress:
        return DetectedCarrier(name: "DHL Express",
                               trackingURL: carrierURL("https://www.dhl.com/global-en/home/tracking/tracking-express.html?submit=1&tracking-id=", number),
                               shopifyCompany: "DHL Express")
    }
}

/// ASCII letters and digits only, so the number can never add a query, fragment or path to the page's address.
private let carrierURLAllowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789")

/// `prefix` + the percent-encoded number, only as an https URL with a host.
func carrierURL(_ prefix: String, _ number: String) -> URL? {
    guard let encoded = number.addingPercentEncoding(withAllowedCharacters: carrierURLAllowed),
          let url = URL(string: prefix + encoded), url.scheme == "https", url.host?.isEmpty == false else { return nil }
    return url
}

/// Digits of an all-digit string, or nil.
private func carrierDigits(_ number: String) -> [Int]? {
    var digits: [Int] = []
    for scalar in number.unicodeScalars {
        guard ("0"..."9").contains(scalar) else { return nil }
        digits.append(Int(scalar.value) - 48)
    }
    return digits
}

/// GS1 mod 10 (USPS IMpb, FedEx Ground 15): weights 3, 1, 3… from the digit next to the check digit.
func carrierGS1CheckDigitValid(_ digits: [Int]) -> Bool {
    guard digits.count >= 2 else { return false }
    let body = digits.dropLast()
    var total = 0
    for (index, digit) in body.reversed().enumerated() { total += digit * (index % 2 == 0 ? 3 : 1) }
    return (10 - total % 10) % 10 == digits[digits.count - 1]
}

/// UPU S10: two letters, eight digits, a check digit (weights 8 6 4 2 3 5 9 7, mod 11; 10 → 0, 11 → 5) and the
/// ISO country code of the postal operator that issued it.
func carrierS10CheckDigitValid(_ number: String) -> Bool {
    let scalars = Array(number.unicodeScalars)
    guard scalars.count == 13,
          scalars[0..<2].allSatisfy({ ("A"..."Z").contains($0) }), scalars[11..<13].allSatisfy({ ("A"..."Z").contains($0) }),
          let digits = carrierDigits(String(String.UnicodeScalarView(scalars[2..<11]))) else { return false }
    let weights = [8, 6, 4, 2, 3, 5, 9, 7]
    let total = zip(digits.prefix(8), weights).reduce(0) { $0 + $1.0 * $1.1 }
    var check = 11 - total % 11
    if check == 10 { check = 0 } else if check == 11 { check = 5 }
    return check == digits[8]
}

/// Postal operators by the S10 country code: name, tracking page prefix (nil where Plinth has no reliable page) and
/// Shopify's exact company name (nil where Shopify doesn't list it). A country not listed isn't recognised.
private let carrierS10Operators: [String: (name: String, url: String?, shopify: String?)] = [
    "US": ("USPS", "https://tools.usps.com/go/TrackConfirmAction?tLabels=", "USPS"),
    "GB": ("Royal Mail", "https://www.royalmail.com/track-your-item#/tracking-results/", "Royal Mail"),
    "CA": ("Canada Post", "https://www.canadapost-postescanada.ca/track-reperage/en#/search?searchFor=", "Canada Post"),
    "AU": ("Australia Post", "https://auspost.com.au/mypost/track/details/", "Australia Post"),
    "NZ": ("New Zealand Post", "https://www.nzpost.co.nz/tools/tracking/item/", "New Zealand Post"),
    "DE": ("Deutsche Post", nil, "Deutsche Post"),
    "IE": ("An Post", nil, "An Post"),
    "NL": ("PostNL", nil, "PostNL"),
    "IT": ("Poste Italiane", nil, "Poste Italiane"),
    "ES": ("Correos", nil, "Correos"),
    "FR": ("La Poste", nil, nil),
    "JP": ("Japan Post", nil, nil),
    "CH": ("Swiss Post", nil, nil)
]

private func carrierFromS10(_ number: String) -> DetectedCarrier? {
    guard carrierS10CheckDigitValid(number), let entry = carrierS10Operators[String(number.suffix(2))] else { return nil }
    return DetectedCarrier(name: entry.name, trackingURL: entry.url.flatMap { carrierURL($0, number) }, shopifyCompany: entry.shopify)
}

/// UPS: "1Z", 15 letters or digits, a check digit (letters as (code − 63) mod 10; every second character doubled).
func carrierIsUPS(_ number: String) -> Bool {
    let scalars = Array(number.unicodeScalars)
    guard scalars.count == 18, scalars[0] == "1", scalars[1] == "Z", let check = carrierDigits(String(scalars[17]))?.first else { return false }
    var total = 0
    for (index, scalar) in scalars[2..<17].enumerated() {
        let value: Int
        if ("0"..."9").contains(scalar) { value = Int(scalar.value) - 48 }
        else if ("A"..."Z").contains(scalar) { value = (Int(scalar.value) - 63) % 10 }
        else { return false }
        total += index % 2 == 1 ? value * 2 : value
    }
    return (10 - total % 10) % 10 == check
}

private enum CarrierIMpb { case usps, shared }

/// USPS Intelligent Mail package barcode: 22 or 26 digits starting 92, 93, 94 or 95, GS1 check digit. 92 numbers are
/// also printed by services that hand parcels to USPS (FedEx Ground Economy), so they're `.shared`.
private func carrierUSPSIMpb(_ number: String) -> CarrierIMpb? {
    guard number.count == 22 || number.count == 26, let digits = carrierDigits(number), carrierGS1CheckDigitValid(digits) else { return nil }
    switch number.prefix(2) {
    case "92": return .shared
    case "93", "94", "95": return .usps
    default: return nil
    }
}

/// FedEx Express: 12 digits; weights 3 1 7 on the first 11, total mod 11 mod 10.
func carrierIsFedEx12(_ number: String) -> Bool {
    guard number.count == 12, let digits = carrierDigits(number) else { return false }
    let weights = [3, 1, 7]
    let total = digits.prefix(11).enumerated().reduce(0) { $0 + $1.element * weights[$1.offset % 3] }
    return total % 11 % 10 == digits[11]
}

/// FedEx Ground: 15 digits, GS1 check digit.
func carrierIsFedEx15(_ number: String) -> Bool {
    guard number.count == 15, let digits = carrierDigits(number) else { return false }
    return carrierGS1CheckDigitValid(digits)
}

/// DHL Express waybill: 10 digits, the first nine mod 7 as the last.
func carrierIsDHLExpress10(_ number: String) -> Bool {
    guard number.count == 10, let digits = carrierDigits(number) else { return false }
    let body = digits.prefix(9).reduce(0) { $0 * 10 + $1 }
    return body % 7 == digits[9]
}
