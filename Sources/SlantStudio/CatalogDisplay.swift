import Foundation

// MARK: - Catalog search

/// The text Catalog's search looks in. Components carry only a `categoryId`, so the category's name — with its parent
/// categories, as in "Hardware › Magnets" — is resolved from the categories already loaded and searched too.
func catalogSearchFields(_ record: Record, categories: [Record] = []) -> [String] {
    var fields = [
        record.string("name"), record.string("description"), record.string("profile"),
        record.string("category"), record.string("categoryName"), record.string("provider"),
        record.string("color")
    ]
    if let tags = record.values["tags"] as? [Any] {
        fields.append(contentsOf: tags.compactMap { metricDisplayValue($0) })
    } else {
        fields.append(record.string("tags"))
    }
    if let path = componentCategoryName(id: record.string("categoryId", "categoryID"), in: categories) {
        fields.append(path)
    }
    return fields.filter { !$0.isEmpty }
}

// MARK: - Catalog facts

/// A finite, non-negative number from a JSON value, written without trailing zeros (at most two decimals), or nil for
/// absent, null, boolean, text that isn't a number, NaN or a negative value.
func catalogNumberText(_ value: Any?) -> String? {
    let number: Double
    if let value = value as? NSNumber {
        guard CFGetTypeID(value) != CFBooleanGetTypeID() else { return nil }
        number = value.doubleValue
    } else if let text = value as? String, let parsed = Double(text.trimmingCharacters(in: .whitespaces)) {
        number = parsed
    } else {
        return nil
    }
    guard number.isFinite, number >= 0, number < 1e12 else { return nil }
    let formatter = NumberFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.numberStyle = .decimal
    formatter.usesGroupingSeparator = false
    formatter.minimumFractionDigits = 0
    formatter.maximumFractionDigits = 2
    return formatter.string(from: NSNumber(value: number))
}

/// A whole number from a JSON value (an integer, or a number or text with no fractional part), or nil.
func catalogWholeNumber(_ value: Any?) -> Int? {
    if let value = value as? NSNumber {
        guard CFGetTypeID(value) != CFBooleanGetTypeID() else { return nil }
        let double = value.doubleValue
        guard double.isFinite, double.rounded() == double, abs(double) < 1e12 else { return nil }
        return Int(double)
    }
    if let text = value as? String { return Int(text.trimmingCharacters(in: .whitespaces)) }
    return nil
}

/// A catalog price with its `priceUnit`. Slant's component `priceUnit` is a currency (the enum `["USD"]`), so a
/// three-letter upper-case code is read as the currency: USD gives "$4.50", another code "4.50 EUR". Anything else is a
/// unit ("$4.50 / each"); none gives "$4.50".
func catalogPriceText(_ price: Any?, priceUnit: String) -> String {
    let unit = priceUnit.trimmingCharacters(in: .whitespacesAndNewlines)
    let amount = money(price)
    guard !unit.isEmpty else { return amount }
    let code = unit.uppercased()
    let letters = code.count == 3 && code.unicodeScalars.allSatisfy { ("A"..."Z").contains($0) }
    // Upper case reads as a currency; lower case only when it is a known ISO code (so "usd" is USD, "pcs" a unit).
    let isCurrencyCode = letters && (unit == code || Locale.Currency.isoCurrencies.contains { $0.identifier == code })
    guard isCurrencyCode else { return "\(amount) / \(unit)" }
    if code == "USD" || amount == "—" { return amount }
    return "\(amount.hasPrefix("$") ? String(amount.dropFirst()) : amount) \(code)"
}

private func catalogText(_ record: Record, _ key: String) -> String {
    guard let text = record.values[key] as? String else { return "" }
    return text.trimmingCharacters(in: .whitespacesAndNewlines)
}

/// Readable facts for a stationery item (Catalog card detail and sheet): price, dimensions, weight, quantity and an
/// not-available note. The Stationery schema has nullable `price` and `weight` and gives no units, so a unit is shown
/// only when Slant sends one (`priceUnit`, `dimensionUnit`, `weightUnit`); none is assumed. What `quantity` counts
/// isn't documented, so it is shown under Slant's own name. Absent, null or odd-typed values are left out.
func stationeryFactRows(_ record: Record) -> [(String, String)] {
    var rows: [(String, String)] = []
    if catalogNumberText(record.values["price"]) != nil {
        rows.append(("Price", catalogPriceText(record.values["price"], priceUnit: catalogText(record, "priceUnit"))))
    }
    let dimensions = catalogText(record, "dimensions")
    if !dimensions.isEmpty {
        let unit = catalogText(record, "dimensionUnit")
        rows.append(("Dimensions", unit.isEmpty ? dimensions : "\(dimensions) \(unit)"))
    }
    if let weight = catalogNumberText(record.values["weight"]) {
        let unit = catalogText(record, "weightUnit")
        rows.append(("Weight", unit.isEmpty ? weight : "\(weight) \(unit)"))
    }
    if let quantity = catalogWholeNumber(record.values["quantity"]), quantity > 0 {
        rows.append(("Quantity", quantity.formatted()))
    }
    if filamentAvailability(record) == false {
        rows.append(("Availability", "Not available"))
    }
    return rows
}

/// A stationery card's second line: its description, else its dimensions, else "Stationery".
func stationeryCardSubtitle(_ record: Record) -> String {
    let description = catalogText(record, "description")
    if !description.isEmpty { return description }
    if let dimensions = stationeryFactRows(record).first(where: { $0.0 == "Dimensions" }) { return dimensions.1 }
    return "Stationery"
}

// MARK: - Material names

/// Material types and other abbreviations kept in capitals when a name is title-cased.
let materialNameAcronyms: Set<String> = [
    "PLA", "PETG", "PET", "OPM", "TPU", "TPE", "CF", "GF", "ABS", "ASA", "PC", "PA", "PP", "PVA", "HIPS", "HT", "HS",
    "UV", "LED", "RGB", "USA", "UK", "EU", "II", "III", "IV"
]

/// Slant's material names arrive in capitals ("PLA MATTE BLACK"); this shows them as "PLA Matte Black". Display only:
/// IDs and every value sent to Slant are unchanged, and search ignores case. Names that already contain a lower-case
/// letter are returned as they are. Within a name, abbreviations in `materialNameAcronyms` and letters touching a
/// digit ("1KG", "3D") stay capitals; every other run of letters becomes "Capitalised".
func materialDisplayName(_ name: String) -> String {
    guard name.contains(where: \.isLowercase) == false, name.contains(where: \.isLetter) else { return name }
    let characters = Array(name)
    var result = ""
    var index = 0
    while index < characters.count {
        guard characters[index].isLetter else {
            result.append(characters[index])
            index += 1
            continue
        }
        var end = index
        while end < characters.count, characters[end].isLetter { end += 1 }
        let run = String(characters[index..<end])
        let touchesDigit = (index > 0 && characters[index - 1].isNumber) || (end < characters.count && characters[end].isNumber)
        if touchesDigit || materialNameAcronyms.contains(run) {
            result += run
        } else {
            result += run.prefix(1).uppercased() + run.dropFirst().lowercased()
        }
        index = end
    }
    return result
}

/// A catalog item's title: materials get `materialDisplayName`, everything else its name as Slant sends it.
func catalogRecordTitle(_ record: Record, kind: Destination) -> String {
    let name = displayName(for: record, fallback: catalogDisplayFallback(kind))
    return kind == .materials ? materialDisplayName(name) : name
}

/// Catalog's cards in the order of their titles (Finder's ordering, so "PLA 2" comes before "PLA 10"); equal titles
/// keep Slant's order. Display only: the Material picker keeps its own grouping.
func catalogRecordsSortedByTitle(_ records: [Record], kind: Destination) -> [Record] {
    records.enumerated()
        .map { (offset: $0.offset, record: $0.element, title: catalogRecordTitle($0.element, kind: kind)) }
        .sorted { a, b in
            let order = a.title.localizedStandardCompare(b.title)
            return order == .orderedSame ? a.offset < b.offset : order == .orderedAscending
        }
        .map(\.record)
}

/// A material's colour for display: Slant sends it in lower case ("black", "light grey"), shown as "Black" and
/// "Light Grey"; all-capital text goes through `materialDisplayName`, and mixed case is kept as sent. Display only.
func catalogColourDisplay(_ raw: String) -> String {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.contains(where: \.isUppercase) { return materialDisplayName(trimmed) }
    return trimmed.split(separator: " ", omittingEmptySubsequences: false)
        .map { $0.prefix(1).uppercased() + $0.dropFirst() }
        .joined(separator: " ")
}

/// The caption beside a material's Use This Material button. The material is the print configuration's (one setting
/// for every model), not a particular model's.
let catalogMaterialUseCaption = "Uses this material in the print configuration and returns to Models."

/// Requests left this minute below which Catalog doesn't load Components or Stationery by itself.
let catalogLoadOnShowReserve = 5

/// True when Components or Stationery should load by itself when first shown, as Materials do: a single read-only
/// GET, tried once a session per kind, only with a key, while nothing else runs and with requests to spare. The Load
/// button stays for anything this skips.
func catalogShouldLoadOnShow(_ kind: Destination, loaded: Bool, hasKey: Bool, busy: Bool, alreadyTried: Bool,
                             rateLimitRemaining: Int?) -> Bool {
    guard kind == .components || kind == .stationery, !loaded, hasKey, !busy, !alreadyTried else { return false }
    if let rateLimitRemaining, rateLimitRemaining <= catalogLoadOnShowReserve { return false }
    return true
}
