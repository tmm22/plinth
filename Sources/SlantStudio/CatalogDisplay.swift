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
        let unit = catalogText(record, "priceUnit")
        rows.append(("Price", unit.isEmpty ? money(record.values["price"]) : "\(money(record.values["price"])) / \(unit)"))
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
