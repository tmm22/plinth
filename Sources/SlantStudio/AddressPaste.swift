import Foundation

// MARK: - Paste Address (order composer)
//
// Reads a delivery address from text the seller pastes — an Etsy or Shopify order's shipping address, or an address
// block from an email — for review before anything in the form changes. The text and the parsed fields stay in the
// composer's memory: never saved, logged or sent anywhere. Phone numbers are ignored, an email is taken only when one
// is written in the text, postcodes are kept exactly as written (never padded), and a country is set only when the
// text names one Studio recognises: an unrecognised one is left for the seller to choose, and when the text names
// none the form's country is kept (and the review says so).

/// Longest text read: an address block is a few hundred characters, so anything longer is cut here.
let addressPasteMaxCharacters = 2_000
/// Most lines (or comma-separated parts) considered.
let addressPasteMaxItems = 30
/// Longest single line kept.
let addressPasteMaxItemLength = 200

/// A delivery address read from pasted text. Memory only.
struct PastedAddress: Equatable {
    var name = ""
    var email = ""
    var line1 = ""
    var line2 = ""
    var city = ""
    var state = ""
    var zip = ""
    /// ISO code; empty when the text names no country, or one Studio doesn't recognise.
    var countryCode = ""
    /// The country as written when it wasn't recognised, so the review can say so.
    var unrecognisedCountry = ""
    /// Lines Studio couldn't place (such as text after the country). Listed in the review so nothing disappears unseen.
    var unused: [String] = []

    /// Enough to be worth applying: a street, a city or a postcode.
    var foundAddress: Bool { [line1, city, zip].contains { !$0.isEmpty } }
}

/// The pasteboard text to start the Paste Address box with: only plain text, and only an address-sized amount.
/// Called only after the seller presses Paste Address…; anything else starts the box empty.
func addressPastePrefill(_ pasteboardText: String?, holdsFileURL: Bool = false) -> String {
    guard !holdsFileURL, let text = pasteboardText,
          !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
          text.count <= addressPasteMaxCharacters else { return "" }
    return text
}

/// What the box starts with, and whether the clipboard's text was left out because it doesn't look like an address
/// (`pastedAddressLooksLikeAddress`). A password, link or note on the clipboard is then never shown on screen; the
/// seller can still paste into the box.
func addressPasteClipboardPrefill(_ pasteboardText: String?, holdsFileURL: Bool = false) -> (text: String, skippedNonAddress: Bool) {
    let text = addressPastePrefill(pasteboardText, holdsFileURL: holdsFileURL)
    guard !text.isEmpty else { return ("", false) }
    return pastedAddressLooksLikeAddress(parsePastedAddressDetecting(text)) ? (text, false) : ("", true)
}

/// A single unbroken run of characters longer than this isn't a street or a town (a password, token or link is).
let addressPasteLongestSingleWord = 25

/// A value with no spaces that is too long to be a street or town name, or that is a link.
func addressPasteValueLooksLikeToken(_ value: String) -> Bool {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return false }
    if trimmed.contains("://") { return true }
    return !trimmed.contains(where: \.isWhitespace) && trimmed.count > addressPasteLongestSingleWord
}

/// Use These Details is offered only for something that looks like an address: a town or postcode was found, and
/// neither the street nor the town is a long unbroken token. Otherwise the popover says "This doesn't look like an
/// address." rather than turning any clipboard text into a street and clearing the form's town and postcode.
func pastedAddressLooksLikeAddress(_ parsed: PastedAddress) -> Bool {
    guard parsed.foundAddress, !parsed.city.isEmpty || !parsed.zip.isEmpty else { return false }
    return !addressPasteValueLooksLikeToken(parsed.line1) && !addressPasteValueLooksLikeToken(parsed.city)
}

// MARK: Applying

/// The composer's delivery details with the pasted address in place. The whole address is replaced — the old
/// apartment or unit never carries over to another building. A country the paste names replaces the form's (an
/// unrecognised one leaves it unselected, never guessed); when the paste names none, the form's country is kept, and
/// the review says so. A name or email is replaced only when the paste has one.
func deliveryDetails(applyingPasted pasted: PastedAddress, to current: DeliveryDetails) -> DeliveryDetails {
    var result = current
    if !pasted.name.isEmpty { result.name = pasted.name }
    if !pasted.email.isEmpty { result.email = pasted.email }
    result.line1 = pasted.line1
    result.line2 = pasted.line2
    result.city = pasted.city
    result.state = pasted.state
    result.zip = pasted.zip
    if pastedAddressNamesNoCountry(pasted) { return result }
    return deliveryApplyingCountryPick(pasted.countryCode, to: result)
}

/// The paste doesn't name a country at all (neither a recognised nor an unrecognised one).
func pastedAddressNamesNoCountry(_ pasted: PastedAddress) -> Bool {
    pasted.countryCode.isEmpty && pasted.unrecognisedCountry.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
}

/// What the review shows for the country.
enum PastedAddressCountryDisplay: Equatable {
    /// The paste names this country (ISO code).
    case pasted(String)
    /// The paste names a country Studio doesn't recognise: the form's country is cleared for the seller to choose.
    case unrecognised(String)
    /// The paste names none, so the form keeps this country (ISO code).
    case keptFromForm(String)
    /// The paste names none and the form has none.
    case missing
}

func pastedAddressCountryDisplay(_ pasted: PastedAddress, current: DeliveryDetails) -> PastedAddressCountryDisplay {
    if !pasted.countryCode.isEmpty { return .pasted(pasted.countryCode) }
    if !pastedAddressNamesNoCountry(pasted) { return .unrecognised(pasted.unrecognisedCountry) }
    let kept = orderCountryPickerValue(current)
    return kept.isEmpty ? .missing : .keptFromForm(kept)
}

/// The popover's replace warning: says when the form's name (and email) are kept because the paste has none.
func pastedAddressReplaceWarning(_ pasted: PastedAddress, current: DeliveryDetails) -> String {
    let base = "This replaces delivery details already in the form."
    let hasName = !current.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    let hasEmail = !current.email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    let keepsName = pasted.name.isEmpty && hasName
    let keepsEmail = pasted.email.isEmpty && hasEmail
    switch (keepsName, keepsEmail) {
    case (true, true): return base + " No name or email was found, so the current name and email are kept."
    case (true, false): return base + " No name was found, so the current name is kept."
    case (false, true): return base + " No email was found, so the current email is kept."
    case (false, false): return base
    }
}

/// Use These Details never silently replaces what's in the form: it asks first when a field that holds something
/// typed or copied would change, or when it would change a country the seller picked. The Mac-region default
/// country alone never counts, as with Use My Address (`useMyAddressNeedsConfirmation`).
func pastedAddressNeedsConfirmation(current: DeliveryDetails, replacement: DeliveryDetails, countryPicked: Bool) -> Bool {
    let pairs: [(String, String)] = [
        (current.name, replacement.name), (current.email, replacement.email), (current.line1, replacement.line1),
        (current.line2, replacement.line2), (current.city, replacement.city), (current.state, replacement.state),
        (current.zip, replacement.zip)
    ]
    let trim = { (value: String) in value.trimmingCharacters(in: .whitespacesAndNewlines) }
    if pairs.contains(where: { !trim($0.0).isEmpty && trim($0.0) != trim($0.1) }) { return true }
    return countryPicked && orderCountryPickerValue(current) != orderCountryPickerValue(replacement)
}

// MARK: Parsing

/// Parses pasted address text with Studio's own rules, then, only when those find no address at all or leave the
/// street run into the city, with the system's address detector (`NSDataDetector`).
func parsePastedAddressDetecting(_ text: String) -> PastedAddress {
    let parsed = parsePastedAddress(text)
    guard !parsed.foundAddress || pastedAddressStreetInCity(parsed) else { return parsed }
    return pastedAddress(parsed, fillingFrom: addressPasteDetectedParts(text))
}

/// No street, and a city that starts with a number: the street and city were written together.
func pastedAddressStreetInCity(_ parsed: PastedAddress) -> Bool {
    parsed.line1.isEmpty && parsed.city.first?.isNumber == true
}

/// What `NSDataDetector` found in the text, if anything.
struct DetectedAddressParts: Equatable {
    var street = ""
    var city = ""
    var state = ""
    var zip = ""
    var country = ""
}

func addressPasteDetectedParts(_ text: String) -> DetectedAddressParts? {
    let bounded = String(text.prefix(addressPasteMaxCharacters))
    guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.address.rawValue) else { return nil }
    let range = NSRange(bounded.startIndex..., in: bounded)
    guard let match = detector.firstMatch(in: bounded, options: [], range: range), let components = match.addressComponents else { return nil }
    func value(_ key: NSTextCheckingKey) -> String { addressPasteClean(components[key] ?? "") }
    let parts = DetectedAddressParts(street: value(.street), city: value(.city), state: value(.state), zip: value(.zip), country: value(.country))
    return parts == DetectedAddressParts() ? nil : parts
}

/// Fills the address fields the rules left empty from detected parts. A detected country is used only when it is
/// one Studio recognises.
func pastedAddress(_ parsed: PastedAddress, fillingFrom detected: DetectedAddressParts?) -> PastedAddress {
    guard let detected else { return parsed }
    var result = parsed
    // "12 Main St Springfield" as the city: the detector's street and city replace it when it found both.
    if pastedAddressStreetInCity(result), !detected.street.isEmpty, !detected.city.isEmpty { result.city = "" }
    if result.line1.isEmpty { result.line1 = detected.street.components(separatedBy: .newlines).first ?? "" }
    if result.city.isEmpty { result.city = detected.city }
    if result.state.isEmpty { result.state = detected.state }
    if result.zip.isEmpty { result.zip = detected.zip }
    if result.countryCode.isEmpty, !detected.country.isEmpty {
        let code = addressPasteCountryCode(detected.country, allowBareCode: true)
        if !code.isEmpty {
            result.countryCode = code
            result.unrecognisedCountry = ""
        }
    }
    // Whatever the detector placed is no longer "not used".
    let placed = Set([result.line1, result.city, result.state, result.zip].map { $0.lowercased() })
    result.unused.removeAll { placed.contains($0.lowercased()) }
    return result
}

/// Studio's rules for common address blocks: a name line, the street, an apartment or unit line, the city, state
/// and postcode (on one line or several), and a country line; an email anywhere; phone numbers and headings such as
/// "Ship to" ignored. One line separated by commas works too, as does a "Label: value" form.
func parsePastedAddress(_ text: String) -> PastedAddress {
    var result = PastedAddress()
    var lines = addressPasteLines(text)

    // An email anywhere: the first one is used; the rest of its line stays (such as a name before "<ada@…>").
    lines = lines.compactMap { line in
        guard line.range(of: addressPasteEmailPattern, options: .regularExpression) != nil else { return line }
        var remainder = line
        while let range = remainder.range(of: addressPasteEmailPattern, options: .regularExpression) {
            let found = String(remainder[range])
            if result.email.isEmpty, isEmailAddress(found) { result.email = found }
            remainder.removeSubrange(range)
        }
        remainder = remainder.replacingOccurrences(of: "mailto:", with: "", options: .caseInsensitive)
        let stripped = addressPasteStrippingLabel(addressPasteClean(remainder))
        if stripped.label == .email { return nil }
        let value = addressPasteClean(stripped.value.trimmingCharacters(in: CharacterSet(charactersIn: "<>()[]:;,").union(.whitespaces)))
        if value.isEmpty || ["email", "e-mail", "email address"].contains(value.lowercased()) { return nil }
        return stripped.label == nil ? value : "\(stripped.rawLabel): \(value)"
    }
    // Phone numbers and headings are dropped.
    lines.removeAll { addressPasteIsPhone($0) || addressPasteIsHeading($0) }

    // A "Label: value" form (City: …, Postcode: …) maps fields directly.
    let labelled = lines.map(addressPasteStrippingLabel)
    let addressLabels: Set<AddressPasteLabel> = [.line1, .line2, .city, .state, .zip, .country]
    if labelled.filter({ $0.label.map(addressLabels.contains) == true && !$0.value.isEmpty }).count >= 2 {
        for entry in labelled {
            switch entry.label {
            case .name?: if result.name.isEmpty { result.name = entry.value }
            case .line1?: if result.line1.isEmpty { result.line1 = entry.value } else { result.line2 = addressPasteJoined(result.line2, entry.value) }
            case .line2?: result.line2 = addressPasteJoined(result.line2, entry.value)
            case .city?: if result.city.isEmpty { result.city = entry.value }
            case .state?: if result.state.isEmpty { result.state = entry.value }
            case .zip?: if result.zip.isEmpty { result.zip = entry.value }
            case .country?: if result.countryCode.isEmpty, result.unrecognisedCountry.isEmpty { setCountry(entry.value, allowBareCode: true) }
            case .phone?, .email?: break
            case .address?: if result.line1.isEmpty { result.line1 = entry.value } else { result.line2 = addressPasteJoined(result.line2, entry.value) }
            case .shipTo?: if result.name.isEmpty { result.name = entry.value } else { result.unused.append(entry.value) }
            case nil: if !entry.value.isEmpty { result.unused.append(entry.value) }
            }
        }
        return result
    }

    // Otherwise each line is one part, with labels such as "Name:" or "Address:" taken off. Short pastes (one or two
    // lines) are split at commas, so "Ada Lovelace, 12 Main St, Springfield, IL 62701, USA" works too.
    var items: [String] = []
    for entry in labelled {
        if entry.label == .name, result.name.isEmpty, !entry.value.isEmpty { result.name = entry.value; continue }
        if !entry.value.isEmpty { items.append(entry.value) }
    }
    if lines.count <= 2 {
        items = items.flatMap { $0.components(separatedBy: CharacterSet(charactersIn: ",;")) }.map(addressPasteClean).filter { !$0.isEmpty }
    }
    items = Array(items.prefix(addressPasteMaxItems))
    guard !items.isEmpty else { return result }

    // The postcode line: the last part that ends (or, as in much of Europe, starts) with a postcode.
    var postcodeIndex: Int?
    var postcode: AddressPastePostcode?
    for index in items.indices.reversed() {
        if let found = addressPastePostcode(in: items[index]) {
            postcodeIndex = index
            postcode = found
            break
        }
    }

    var head: [String]
    if let p = postcodeIndex, let postcode {
        result.zip = postcode.code
        // Parts after the postcode line: a country, then anything else Studio can't place.
        let tail = Array(items[(p + 1)...])
        if let first = tail.first { setCountry(first, allowBareCode: true) }
        result.unused.append(contentsOf: tail.dropFirst())
        head = Array(items[..<p])
        if !postcode.city.isEmpty { result.city = postcode.city }
        if !postcode.state.isEmpty { result.state = postcode.state }
        if result.city.isEmpty {
            // City (and perhaps a state or county) on the lines just before a postcode written on its own.
            let run = addressPasteTrailingPlaceRun(head)
            if result.state.isEmpty, run.count >= 2, addressPasteIsRegion(run[run.count - 1], allowNames: true, allowCounties: true) {
                result.state = run[run.count - 1]
                result.city = run[run.count - 2]
                head.removeLast(2)
            } else if let last = run.last {
                result.city = last
                head.removeLast()
            } else if head.count == 1, addressPasteIsPlaceName(head[0]) {
                // Only a place before the postcode ("London, SW1A 1AA" or "Springfield, IL 62701"): the town.
                result.city = head.removeFirst()
            }
        }
    } else {
        // No postcode: a recognised country name on the last line, and the city just before it.
        head = items
        if let last = head.last, !addressPasteCountryCode(last, allowBareCode: false).isEmpty {
            setCountry(last, allowBareCode: false)
            head.removeLast()
            if head.count >= 2, let city = head.last, !addressPasteHasDigit(city), !addressPasteIsUnit(city) {
                result.city = city
                head.removeLast()
            }
        }
    }

    // The rest: a name first, then the street, apartment or unit lines, and anything else.
    if result.name.isEmpty, let first = head.first, addressPasteFirstLineIsName(first, following: head.dropFirst()) {
        result.name = first
        head.removeFirst()
    }
    // "c/o …" and "Attn …" lines lead line 2; they're never the street.
    var careOf: [String] = []
    var units: [String] = []
    var others: [String] = []
    for item in head {
        if addressPasteIsCareOf(item) {
            careOf.append(item)
        } else if let split = addressPasteSplittingLeadingUnit(item) {
            units.append(split.unit)
            others.append(split.street)
        } else if addressPasteIsUnit(item) {
            units.append(item)
        } else {
            others.append(item)
        }
    }
    let streetIndex = others.firstIndex(where: addressPasteHasDigit) ?? others.firstIndex(where: addressPasteLooksLikeStreet) ?? others.indices.first
    // Line 2: c/o and attention lines, then lines between the name and the street (a company, a house or building
    // name), then the apartment or unit, then anything after the street.
    var extraLines = careOf
    if let streetIndex {
        let street = addressPasteSplittingUnit(others[streetIndex])
        result.line1 = street.street
        extraLines.append(contentsOf: others[..<streetIndex])
        if let unit = street.unit { extraLines.append(unit) }
        extraLines.append(contentsOf: units)
        extraLines.append(contentsOf: others[(streetIndex + 1)...])
    } else {
        extraLines.append(contentsOf: units)
    }
    result.line2 = extraLines.joined(separator: ", ")
    // A one-line paste without commas leaves the street in front of the city ("12 Main St Springfield"): split
    // after the last street word.
    if result.line1.isEmpty, result.city.first?.isNumber == true {
        let words = result.city.split(separator: " ").map(String.init)
        if let index = words.indices.dropLast().last(where: { addressPasteStreetWords.contains(words[$0].lowercased()) }) {
            result.line1 = words[...index].joined(separator: " ")
            result.city = words[(index + 1)...].joined(separator: " ")
        }
    }
    return result

    func setCountry(_ text: String, allowBareCode: Bool) {
        let code = addressPasteCountryCode(text, allowBareCode: allowBareCode)
        if code.isEmpty {
            result.countryCode = ""
            result.unrecognisedCountry = text
        } else {
            result.countryCode = code
            result.unrecognisedCountry = ""
        }
    }
}

// MARK: Parsing helpers

let addressPasteEmailPattern = #"[A-Z0-9a-z._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}"#

/// Trimmed lines, with tabs and no-break spaces as plain spaces and runs of spaces collapsed. Bounded in size.
func addressPasteLines(_ text: String) -> [String] {
    let bounded = String(text.prefix(addressPasteMaxCharacters))
    return bounded.components(separatedBy: .newlines)
        .map(addressPasteClean)
        .filter { !$0.isEmpty }
        .prefix(addressPasteMaxItems)
        .map { String($0.prefix(addressPasteMaxItemLength)) }
}

func addressPasteClean(_ text: String) -> String {
    var value = text.replacingOccurrences(of: "\u{00A0}", with: " ").replacingOccurrences(of: "\t", with: " ")
    while value.contains("  ") { value = value.replacingOccurrences(of: "  ", with: " ") }
    return value.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: ",;"))
        .trimmingCharacters(in: .whitespaces)
}

func addressPasteJoined(_ first: String, _ second: String) -> String {
    [first, second].filter { !$0.isEmpty }.joined(separator: ", ")
}

func addressPasteHasDigit(_ text: String) -> Bool {
    text.rangeOfCharacter(from: .decimalDigits) != nil
}

enum AddressPasteLabel: Equatable, Hashable {
    case name, email, phone, line1, line2, city, state, zip, country, address, shipTo
}

private let addressPasteLabels: [(names: [String], label: AddressPasteLabel)] = [
    (["name", "full name", "recipient", "recipient name", "customer name", "buyer name", "contact name"], .name),
    (["email", "e-mail", "email address", "e-mail address"], .email),
    (["phone", "phone number", "tel", "telephone", "mobile", "mobile number", "cell", "ph"], .phone),
    (["address line 1", "address 1", "address1", "line 1", "street", "street address", "street line 1"], .line1),
    (["address line 2", "address 2", "address2", "line 2", "apartment", "apt", "suite", "unit", "street line 2"], .line2),
    (["city", "town", "town/city", "city/town", "suburb", "locality"], .city),
    (["state", "province", "county", "region", "state/province", "state / province", "state/region"], .state),
    (["zip", "zip code", "zipcode", "postal code", "postcode", "post code", "zip/postal code", "postal/zip code"], .zip),
    (["country", "country/region", "country / region"], .country),
    (["address", "shipping address", "delivery address", "mailing address"], .address),
    (["ship to", "shipping to", "deliver to", "send to"], .shipTo)
]

/// A line's "Label:" taken off when it is one Studio knows.
func addressPasteStrippingLabel(_ line: String) -> (label: AddressPasteLabel?, rawLabel: String, value: String) {
    guard let colon = line.firstIndex(where: { $0 == ":" || $0 == "：" }) else { return (nil, "", line) }
    let rawLabel = line[..<colon].trimmingCharacters(in: .whitespaces)
    let key = rawLabel.lowercased()
    guard let match = addressPasteLabels.first(where: { $0.names.contains(key) }) else { return (nil, "", line) }
    return (match.label, rawLabel, addressPasteClean(String(line[line.index(after: colon)...])))
}

/// A phone number on its own line (optionally labelled): at least 7 digits and nothing else but separators. A phone
/// word without a colon counts too ("Phone (555) 123-4567", "Tel 555 0100", "Mobile 07700 900123"), so the number is
/// never read as a postcode; "Mobile" needs a phone-length number, because it is also a city ("Mobile, AL 36602").
func addressPasteIsPhone(_ line: String) -> Bool {
    let stripped = addressPasteStrippingLabel(line)
    if stripped.label == .phone { return true }
    if let worded = addressPastePhoneWordValue(stripped.value) {
        let digits = worded.value.filter(\.isNumber).count
        guard addressPasteIsPhoneCharacters(worded.value), digits <= 20 else { return false }
        return worded.alsoAPlace ? addressPasteIsPhoneNumber(worded.value) : digits >= 3
    }
    return addressPasteIsPhoneNumber(stripped.value)
}

/// Digits and the separators of a phone number, optionally with an extension.
private func addressPasteIsPhoneCharacters(_ value: String) -> Bool {
    value.range(of: #"^\+?[\d\s().\-/]+((ext|x)\.?\s*\d+)?$"#, options: [.regularExpression, .caseInsensitive]) != nil
}

/// A bare phone number: 7 to 20 digits, and not shaped like a postcode written on its own line.
private func addressPasteIsPhoneNumber(_ value: String) -> Bool {
    // Postcodes shaped like numbers: a US ZIP+4, Japan's or Brazil's, on a line of their own.
    if value.range(of: #"^(\d{5}-\d{4}|\d{3}-\d{4}|\d{5}-\d{3})$"#, options: .regularExpression) != nil { return false }
    guard addressPasteIsPhoneCharacters(value) else { return false }
    return (7...20).contains(value.filter(\.isNumber).count)
}

/// The text after a leading phone word with no colon ("Tel. 555 0100" → "555 0100"), or nil. `alsoAPlace`: the word
/// is also a place name (Mobile, Alabama).
private func addressPastePhoneWordValue(_ line: String) -> (value: String, alsoAPlace: Bool)? {
    let pattern = #"^(cell phone|mobile phone|telephone|phone|tel|ph|cell|mobile|mob)\b(\s*(number|no\.?))?[\s.#:]*(.+)$"#
    guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
          let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
          let wordRange = Range(match.range(at: 1), in: line), let valueRange = Range(match.range(at: 4), in: line) else { return nil }
    let word = line[wordRange].lowercased()
    // "Mobile" is also a city and "PH 301" a penthouse unit: those need a phone-length number.
    return (addressPasteClean(String(line[valueRange])), word == "mobile" || word == "mob" || word == "ph")
}

/// Headings such as "Ship to" or "Shipping address:" on a line of their own.
func addressPasteIsHeading(_ line: String) -> Bool {
    line.range(of: #"^(ship(ping)?( to| address)?|deliver(y)?( to| address)?|send to|address|recipient|customer|buyer|mailing address)\s*:?$"#,
               options: [.regularExpression, .caseInsensitive]) != nil
}

private let addressPasteUnitKeyword = #"(?:apt|apartment|unit|suite|ste|flat|floor|fl|room|rm|bldg|building|lot|level|lvl|dept|department)"#
private let addressPasteUnitToken = #"(?:[A-Za-z]?\d[\w/\-]*|[A-Za-z]\b)"#

/// An apartment, suite, unit or flat line: "Apt 4", "Suite 200", "Unit B", "#12", "Flat 3A".
func addressPasteIsUnit(_ line: String) -> Bool {
    line.range(of: "^(?:\(addressPasteUnitKeyword)(?:\\b|(?=\\d))\\.?\\s*#?\\s*|#\\s*)\(addressPasteUnitToken)", options: [.regularExpression, .caseInsensitive]) != nil
}

/// "Unit 5, 20 George St" → unit "Unit 5", street "20 George St". Nil unless a numbered street follows the unit.
func addressPasteSplittingLeadingUnit(_ line: String) -> (unit: String, street: String)? {
    guard addressPasteIsUnit(line), let comma = line.firstIndex(of: ",") else { return nil }
    let unit = addressPasteClean(String(line[..<comma]))
    let street = addressPasteClean(String(line[line.index(after: comma)...]))
    guard !unit.isEmpty, addressPasteHasDigit(street), !addressPasteIsUnit(street) else { return nil }
    return (unit, street)
}

/// "12 Main St, Apt 4" → street "12 Main St", unit "Apt 4". A street without a trailing unit is returned whole.
func addressPasteSplittingUnit(_ line: String) -> (street: String, unit: String?) {
    let pattern = "^(.*\\d.*?)\\s*,?\\s+((?:\(addressPasteUnitKeyword)(?:\\b|(?=\\d))\\.?\\s*#?\\s*|#\\s*)\(addressPasteUnitToken).*)$"
    guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
          let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
          let streetRange = Range(match.range(at: 1), in: line), let unitRange = Range(match.range(at: 2), in: line) else {
        return (line, nil)
    }
    let street = addressPasteClean(String(line[streetRange]))
    guard addressPasteHasDigit(street) else { return (line, nil) }
    return (street, addressPasteClean(String(line[unitRange])))
}

private let addressPasteStreetWords: Set<String> = [
    "street", "st", "st.", "road", "rd", "rd.", "avenue", "ave", "ave.", "lane", "ln", "drive", "dr", "dr.", "boulevard",
    "blvd", "way", "court", "ct", "place", "pl", "close", "crescent", "terrace", "parade", "highway", "hwy", "square",
    "sq", "row", "mews", "grove", "gardens", "hill", "walk", "circle", "cir", "trail", "parkway", "pkwy", "box"
]

/// Ends with a street word ("Main Street", "High Rd") or is a PO box.
func addressPasteLooksLikeStreet(_ line: String) -> Bool {
    let words = line.lowercased().split(separator: " ").map(String.init)
    guard let last = words.last else { return false }
    return addressPasteStreetWords.contains(last) || addressPasteIsPOBox(line)
}

func addressPasteIsPOBox(_ line: String) -> Bool {
    line.range(of: #"^p\.?\s?o\.?\s*box\b"#, options: [.regularExpression, .caseInsensitive]) != nil
}

/// A "c/o …", "Attn …", "Attention …" or "FAO …" line, which belongs in address line 2.
func addressPasteIsCareOf(_ line: String) -> Bool {
    line.range(of: #"^(c/o|c\.o\.|care of|attn|attention|fao|f\.a\.o\.)(\b|(?=\s)|:|\.)"#,
               options: [.regularExpression, .caseInsensitive]) != nil
}

/// Whether the first remaining line is the recipient's name: no digit, not a unit, c/o or PO box line, and either not
/// shaped like a street, or followed (past any c/o or attention lines) by a numbered street or a PO box — so
/// "Damon Hill" above "12 Main St" is a name although it ends in a street word.
func addressPasteFirstLineIsName(_ first: String, following: ArraySlice<String>) -> Bool {
    guard !addressPasteHasDigit(first), !addressPasteIsUnit(first), !addressPasteIsCareOf(first),
          !addressPasteIsPOBox(first) else { return false }
    guard addressPasteLooksLikeStreet(first) else { return true }
    // "Rose Court" or "Kings Place" above the street is a building, not a buyer.
    if addressPasteEndsInBuildingWord(first) { return false }
    guard let next = following.first(where: { !addressPasteIsCareOf($0) }) else { return false }
    if addressPasteIsPOBox(next) { return true }
    return addressPasteHasDigit(next) && (!addressPasteIsUnit(next) || addressPasteSplittingLeadingUnit(next) != nil)
}

/// A line ending in a word that names a building more often than a surname ("Rose Court", "Victoria Gardens").
func addressPasteEndsInBuildingWord(_ line: String) -> Bool {
    let words = line.lowercased().split(whereSeparator: { !$0.isLetter })
    guard let last = words.last else { return false }
    return addressPasteBuildingWords.contains(String(last))
}

let addressPasteBuildingWords: Set<String> = [
    "court", "place", "gardens", "mews", "square", "house", "cottage", "cottages", "lodge", "farm", "manor", "barn",
    "villa", "mansions", "buildings", "apartments", "tower", "towers"
]

/// The lines just before a postcode written on its own line that can be a place: no digits (except a district
/// number such as "Dublin 2"), not a unit line, and never the first line (usually the name). At most two.
func addressPasteTrailingPlaceRun(_ head: [String]) -> [String] {
    var run: [String] = []
    var index = head.count - 1
    while index >= 1, run.count < 2, addressPasteIsPlaceName(head[index]) {
        run.insert(head[index], at: 0)
        index -= 1
    }
    return run
}

/// Letters, spaces and the punctuation of place names, optionally ending in a district number ("Dublin 2").
func addressPasteIsPlaceName(_ text: String) -> Bool {
    !addressPasteIsUnit(text) && text.range(of: #"^\p{L}[\p{L} .,'’\-]*( \d{1,2})?$"#, options: .regularExpression) != nil
}

/// A postcode found in one part, with the city and state written before (or after) it on that part.
struct AddressPastePostcode: Equatable {
    var code: String
    var city = ""
    var state = ""
}

/// Postcode shapes Studio recognises at the end of a part, most specific first: US ZIP (and ZIP+4), Canada, UK,
/// Ireland's Eircode, Japan, Brazil, then 4–6 digits (Australia, New Zealand, much of Europe, India).
private let addressPasteTrailingPostcodePatterns = [
    #"\d{5}(?:-\d{4})?"#,
    #"[A-Za-z]\d[A-Za-z][ \-]?\d[A-Za-z]\d"#,
    #"[A-Za-z]{1,2}\d[A-Za-z\d]? ?\d[A-Za-z]{2}"#,
    #"[A-Za-z]\d[\dWw] ?[A-Za-z\d]{4}"#,
    #"\d{3}-\d{4}"#,
    #"\d{5}-\d{3}"#,
    #"\d{4,6}"#
]

/// Postcodes written before the town, as in "10115 Berlin", "75008 Paris", "1012 AB Amsterdam" or "00-950 Warszawa".
private let addressPasteLeadingPostcodePattern = #"^(\d{4} ?[A-Za-z]{2}|\d{2}-\d{3}|\d{3}-\d{4}|\d{4,6})\s+(\D.*)$"#

func addressPastePostcode(in item: String) -> AddressPastePostcode? {
    guard !addressPasteIsUnit(item) else { return nil }
    for (index, pattern) in addressPasteTrailingPostcodePatterns.enumerated() {
        guard let regex = try? NSRegularExpression(pattern: "^(.*?)[\\s,]*(?<![\\w-])(\(pattern))$", options: []),
              let match = regex.firstMatch(in: item, range: NSRange(item.startIndex..., in: item)),
              let beforeRange = Range(match.range(at: 1), in: item), let codeRange = Range(match.range(at: 2), in: item) else { continue }
        let before = addressPasteClean(String(item[beforeRange]))
        let code = String(item[codeRange])
        // Plain digits count only after a place name (or nothing): after a street, a PO box or other text they are
        // a house number or a reference ("1 Route 6600", "PO Box 1234", "Order #1234").
        if index == addressPasteTrailingPostcodePatterns.count - 1, !before.isEmpty,
           !addressPasteIsPlaceName(before) || addressPasteLooksLikeStreet(before) { continue }
        if addressPasteIsUnit(before) { continue }
        let place = addressPastePlace(before)
        return AddressPastePostcode(code: code, city: place.city, state: place.state)
    }
    if let regex = try? NSRegularExpression(pattern: addressPasteLeadingPostcodePattern, options: []),
       let match = regex.firstMatch(in: item, range: NSRange(item.startIndex..., in: item)),
       let codeRange = Range(match.range(at: 1), in: item), let cityRange = Range(match.range(at: 2), in: item) {
        let city = addressPasteClean(String(item[cityRange]))
        // A street such as "1600 Pennsylvania Avenue" isn't a postcode and town.
        if addressPasteLooksLikeStreet(city) || addressPasteIsUnit(city) { return nil }
        return AddressPastePostcode(code: String(item[codeRange]), city: city)
    }
    return nil
}

/// The city and state written before a postcode: "Springfield, IL", "New York NY", "Sydney NSW", "Toronto Ontario",
/// "Cambridge, Cambridgeshire" or just "London". A state on its own ("IL") leaves the city to the line before.
func addressPastePlace(_ before: String) -> (city: String, state: String) {
    guard !before.isEmpty else { return ("", "") }
    if before.contains(",") {
        let parts = before.components(separatedBy: ",").map(addressPasteClean).filter { !$0.isEmpty }
        guard let first = parts.first else { return ("", "") }
        return parts.count == 1 ? (first, "") : (first, parts[parts.count - 1])
    }
    let words = before.split(separator: " ").map(String.init)
    if words.count == 1 {
        return addressPasteIsRegion(before, allowNames: false, allowCounties: false) ? ("", before) : (before, "")
    }
    // The longest ending of one to three words that names a state or province, leaving a city in front.
    for length in stride(from: min(3, words.count - 1), through: 1, by: -1) {
        let suffix = words.suffix(length).joined(separator: " ")
        if addressPasteIsRegion(suffix, allowNames: true, allowCounties: true) {
            return (words.dropLast(length).joined(separator: " "), suffix)
        }
    }
    return (before, "")
}

/// A US state, Canadian province or Australian state, by its postal abbreviation, or with `allowNames` by name;
/// with `allowCounties`, also a UK county (named only where the county isn't also a town's name).
func addressPasteIsRegion(_ text: String, allowNames: Bool, allowCounties: Bool) -> Bool {
    let key = text.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
    if addressPasteRegionAbbreviations.contains(key) { return true }
    if allowNames, addressPasteRegionNames.contains(key) { return true }
    if allowCounties, addressPasteUKCounties.contains(key) { return true }
    return false
}

private let addressPasteRegionAbbreviations: Set<String> = [
    // United States, DC and territories
    "al", "ak", "az", "ar", "ca", "co", "ct", "de", "fl", "ga", "hi", "id", "il", "in", "ia", "ks", "ky", "la", "me",
    "md", "ma", "mi", "mn", "ms", "mo", "mt", "ne", "nv", "nh", "nj", "nm", "ny", "nc", "nd", "oh", "ok", "or", "pa",
    "ri", "sc", "sd", "tn", "tx", "ut", "vt", "va", "wa", "wv", "wi", "wy", "dc", "pr", "vi", "gu", "as", "mp",
    "aa", "ae", "ap",
    // Canada
    "ab", "bc", "mb", "nb", "nl", "ns", "nt", "nu", "on", "pe", "qc", "sk", "yt",
    // Australia
    "nsw", "vic", "qld", "sa", "wa", "tas", "nt", "act"
]

private let addressPasteRegionNames: Set<String> = [
    "alabama", "alaska", "arizona", "arkansas", "california", "colorado", "connecticut", "delaware", "florida",
    "georgia", "hawaii", "idaho", "illinois", "indiana", "iowa", "kansas", "kentucky", "louisiana", "maine", "maryland",
    "massachusetts", "michigan", "minnesota", "mississippi", "missouri", "montana", "nebraska", "nevada",
    "new hampshire", "new jersey", "new mexico", "new york", "north carolina", "north dakota", "ohio", "oklahoma",
    "oregon", "pennsylvania", "rhode island", "south carolina", "south dakota", "tennessee", "texas", "utah", "vermont",
    "virginia", "washington", "west virginia", "wisconsin", "wyoming", "district of columbia", "puerto rico",
    "alberta", "british columbia", "manitoba", "new brunswick", "newfoundland and labrador", "nova scotia",
    "northwest territories", "nunavut", "ontario", "prince edward island", "quebec", "québec", "saskatchewan", "yukon",
    "new south wales", "victoria", "queensland", "south australia", "western australia", "tasmania",
    "northern territory", "australian capital territory"
]

private let addressPasteUKCounties: Set<String> = [
    "bedfordshire", "berkshire", "buckinghamshire", "cambridgeshire", "cheshire", "cornwall", "cumbria", "derbyshire",
    "devon", "dorset", "east sussex", "west sussex", "essex", "gloucestershire", "greater london", "greater manchester",
    "hampshire", "herefordshire", "hertfordshire", "isle of wight", "kent", "lancashire", "leicestershire",
    "lincolnshire", "merseyside", "norfolk", "north yorkshire", "south yorkshire", "west yorkshire", "east riding of yorkshire",
    "northamptonshire", "northumberland", "nottinghamshire", "oxfordshire", "rutland", "shropshire", "somerset",
    "staffordshire", "suffolk", "surrey", "tyne and wear", "warwickshire", "west midlands", "wiltshire",
    "worcestershire", "county durham", "co. durham", "middlesex", "county antrim", "county down", "county armagh",
    "county tyrone", "county fermanagh", "county londonderry", "aberdeenshire", "fife", "lanarkshire", "midlothian",
    "perthshire", "renfrewshire", "ayrshire", "highland", "gwynedd", "powys", "pembrokeshire", "carmarthenshire",
    "denbighshire", "flintshire", "monmouthshire", "ceredigion", "conwy", "anglesey", "isle of anglesey"
]

private let addressPasteCountryAliases: [String: String] = [
    "usa": "US", "u.s.a.": "US", "u.s.": "US", "united states of america": "US", "america": "US",
    "uk": "GB", "u.k.": "GB", "great britain": "GB", "britain": "GB", "england": "GB", "scotland": "GB",
    "wales": "GB", "northern ireland": "GB", "united kingdom of great britain and northern ireland": "GB"
]

/// The ISO code for a country line, or empty. Names (in English or the Mac's language) and common aliases such as
/// "USA" or "England" are recognised; a bare two-letter code only with `allowBareCode` (after a postcode or under a
/// "Country:" label), because on its own "IL" or "CA" is more likely a state than Israel or Canada.
func addressPasteCountryCode(_ text: String, allowBareCode: Bool) -> String {
    let trimmed = text.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty, !addressPasteHasDigit(trimmed) else { return "" }
    if let alias = addressPasteCountryAliases[trimmed.lowercased()] { return alias }
    if isCountryCode(trimmed), !allowBareCode { return "" }
    let code = orderImportCountryCode(trimmed)
    return orderNonCountryRegionCodes.contains(code) ? "" : code
}

/// When the paste names no country and the form's is kept, a warning if the pasted postcode doesn't fit that
/// country ("SW1A 1AA" with United States kept), so a foreign address isn't sent with the wrong country unnoticed.
func pastedAddressKeptCountryWarning(_ pasted: PastedAddress, keptCode: String) -> String? {
    guard postcodeFormatWarning(pasted.zip, country: keptCode) != nil else { return nil }
    let name = Locale.current.localizedString(forRegionCode: keptCode) ?? keptCode
    return "\(name) is kept from the form, but \(pasted.zip) doesn’t look like a postcode there. Choose the country in the form."
}
