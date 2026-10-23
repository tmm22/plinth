import Foundation
import SwiftUI

// MARK: - Profit check on a real order
//
// Uses the order's own Slant total (print + delivery, in USD) rather than an estimate, because estimates exclude
// shipping. What the buyer paid, how many units they bought and whether the sale came from an ad are typed in for this
// order only and never stored; only the fee preset and its rates are remembered (UserDefaults), since they are
// settings, not personal data.

/// When the preset fee rates were last checked against the marketplaces' published fees.
let profitFeeRatesCheckedDate = "October 2026"
/// Etsy caps the Offsite Ads fee at $100 per order.
let etsyOffsiteAdsCap: Decimal = 100
/// Input limits: anything above these is almost certainly a typo.
let profitMoneyInputLimit: Decimal = 1_000_000
let profitPercentInputLimit: Decimal = 100

enum ProfitFeePreset: String, CaseIterable, Identifiable {
    case none, etsyUS, shopifyBasicUS, custom
    var id: String { rawValue }
    var title: String {
        switch self {
        case .none: return "None"
        case .etsyUS: return "Etsy (US)"
        case .shopifyBasicUS: return "Shopify Payments (US Basic)"
        case .custom: return "Custom"
        }
    }
    /// Published US rates as checked on `profitFeeRatesCheckedDate`. Assumptions: the user can edit every one.
    var defaultRates: ProfitFeeRates {
        switch self {
        case .none, .custom: return ProfitFeeRates()
        case .etsyUS:
            return ProfitFeeRates(transactionPercent: Decimal(string: "6.5")!, processingPercent: 3,
                                  processingFixed: Decimal(string: "0.25")!, listingFeePerItem: Decimal(string: "0.20")!,
                                  offsiteAdsPercent: 15)
        case .shopifyBasicUS:
            return ProfitFeeRates(processingPercent: Decimal(string: "2.9")!, processingFixed: Decimal(string: "0.30")!)
        }
    }
    /// Whether this preset has fee fields to show and edit.
    var hasRates: Bool { self != .none }
    var offersOffsiteAds: Bool { self == .etsyUS }
}

/// Marketplace fee rates. Percentages are in percent (6.5 means 6.5%); fixed fees are USD.
struct ProfitFeeRates: Equatable {
    /// Charged on item + shipping (Etsy's transaction fee).
    var transactionPercent: Decimal = 0
    /// Payment processing, charged on item + shipping, plus a fixed amount per order.
    var processingPercent: Decimal = 0
    var processingFixed: Decimal = 0
    /// Per item sold (Etsy renews a multi-quantity listing for each item sold).
    var listingFeePerItem: Decimal = 0
    /// Etsy Offsite Ads, charged on item + shipping when a sale came from an ad, capped at `etsyOffsiteAdsCap`.
    var offsiteAdsPercent: Decimal = 0
}

enum ProfitRateField: String, CaseIterable {
    case transactionPercent, processingPercent, processingFixed, listingFeePerItem, offsiteAdsPercent
    var isPercent: Bool { self == .transactionPercent || self == .processingPercent || self == .offsiteAdsPercent }
}

extension ProfitFeeRates {
    subscript(field: ProfitRateField) -> Decimal {
        get {
            switch field {
            case .transactionPercent: return transactionPercent
            case .processingPercent: return processingPercent
            case .processingFixed: return processingFixed
            case .listingFeePerItem: return listingFeePerItem
            case .offsiteAdsPercent: return offsiteAdsPercent
            }
        }
        set {
            switch field {
            case .transactionPercent: transactionPercent = newValue
            case .processingPercent: processingPercent = newValue
            case .processingFixed: processingFixed = newValue
            case .listingFeePerItem: listingFeePerItem = newValue
            case .offsiteAdsPercent: offsiteAdsPercent = newValue
            }
        }
    }
}

// MARK: Input parsing

/// Parses a typed amount: digits with an optional decimal point or decimal comma, an optional leading "$" or "US$"
/// or trailing "USD", and grouping separators ("1,234.50", "1.234,50", "1 234,50"). Negative numbers, letters,
/// more than one decimal mark and values above `limit` give nil. A lone separator followed by exactly three digits
/// ("1,234" or "1.234") is read as grouping when that separator isn't the locale's decimal mark.
func parseProfitAmount(_ text: String, decimalSeparator: String = Locale.current.decimalSeparator ?? ".",
                       limit: Decimal = profitMoneyInputLimit) -> Decimal? {
    var value = text.trimmingCharacters(in: .whitespacesAndNewlines)
    for prefix in ["US$", "$"] where value.hasPrefix(prefix) { value.removeFirst(prefix.count) }
    if value.uppercased().hasSuffix("USD") { value.removeLast(3) }
    value = value.filter { !$0.isWhitespace && $0 != "\u{00A0}" && $0 != "\u{202F}" && $0 != "'" }
    guard !value.isEmpty, value.allSatisfy({ $0.isASCII && ($0.isNumber || $0 == "." || $0 == ",") }) else { return nil }
    let commas = value.filter { $0 == "," }.count
    let dots = value.filter { $0 == "." }.count
    var normalized: String
    if commas > 0, dots > 0 {
        // The last mark is the decimal one; the other must be grouping.
        let lastComma = value.lastIndex(of: ",")!
        let lastDot = value.lastIndex(of: ".")!
        let decimalMark: Character = lastComma > lastDot ? "," : "."
        let groupMark: Character = decimalMark == "," ? "." : ","
        guard value.filter({ $0 == decimalMark }).count == 1 else { return nil }
        normalized = value.filter { $0 != groupMark }
        if decimalMark == "," { normalized = normalized.replacingOccurrences(of: ",", with: ".") }
        // Grouping must sit in threes before the decimal mark.
        let integerPart = value[..<(decimalMark == "," ? lastComma : lastDot)]
        guard profitGroupingIsValid(String(integerPart), mark: groupMark) else { return nil }
    } else if commas > 0 || dots > 0 {
        let mark: Character = commas > 0 ? "," : "."
        let count = max(commas, dots)
        let parts = value.split(separator: mark, omittingEmptySubsequences: false)
        let looksGrouped = profitGroupingIsValid(value, mark: mark) && parts.count > 1
        if count > 1 {
            guard looksGrouped else { return nil }
            normalized = value.filter { $0 != mark }
        } else if looksGrouped, String(mark) != decimalSeparator {
            normalized = value.filter { $0 != mark }
        } else {
            normalized = value.replacingOccurrences(of: String(mark), with: ".")
        }
    } else {
        normalized = value
    }
    guard normalized.range(of: #"^(\d+(\.\d*)?|\.\d+)$"#, options: .regularExpression) != nil,
          let decimal = Decimal(string: normalized, locale: Locale(identifier: "en_US_POSIX")),
          !decimal.isNaN, decimal >= 0, decimal <= limit else { return nil }
    return decimal
}

/// "1,234,567" style: a 1–3 digit lead group, then groups of exactly three digits.
private func profitGroupingIsValid(_ text: String, mark: Character) -> Bool {
    let parts = text.split(separator: mark, omittingEmptySubsequences: false)
    guard let first = parts.first, (1...3).contains(first.count) else { return parts.count == 1 }
    return parts.dropFirst().allSatisfy { $0.count == 3 }
}

/// Parses a percentage field (0–100).
func parseProfitPercent(_ text: String, decimalSeparator: String = Locale.current.decimalSeparator ?? ".") -> Decimal? {
    var value = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if value.hasSuffix("%") { value.removeLast() }
    return parseProfitAmount(value, decimalSeparator: decimalSeparator, limit: profitPercentInputLimit)
}

/// Canonical text for a rate (POSIX, no grouping), used for persistence and to fill the fields.
func profitRateText(_ value: Decimal) -> String {
    NSDecimalNumber(decimal: value).stringValue
}

// MARK: Slant total

enum ProfitSlantTotal: Equatable {
    case amount(Decimal)
    case unavailable(String)
}

/// The order's Slant total in USD, read strictly (numbers, or numeric strings like "12.50"), using the same
/// precedence as the order list: total, totalCost, then printing + delivery cost. A partial cost isn't a total, so
/// printing without delivery (or the reverse) is reported as unavailable rather than understated.
func profitCheckSlantTotal(_ order: [String: Any]) -> ProfitSlantTotal {
    let status = ((order["status"] as? String) ?? "").uppercased()
    if status == "CANCELED" || status == "CANCELLED" {
        return .unavailable("This order was cancelled, so there’s no sale to check.")
    }
    if let currency = (order["currency"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
       !currency.isEmpty, currency.uppercased() != "USD" {
        return .unavailable("Slant returned this order’s costs in \(currency), and the profit check only works in USD.")
    }
    let unusable = ProfitSlantTotal.unavailable("Slant hasn’t returned a usable total for this order yet. Reload it after the draft is calculated.")
    func present(_ key: String) -> Bool { order[key] != nil && !(order[key] is NSNull) }
    let total: Decimal?
    if present("total") {
        total = estimateAmount(order["total"])
    } else if present("totalCost") {
        total = estimateAmount(order["totalCost"])
    } else if present("printingCost") || present("deliveryCost") {
        guard let print = estimateAmount(order["printingCost"]), let delivery = estimateAmount(order["deliveryCost"]) else {
            return .unavailable("Slant returned only part of this order’s cost, so the total isn’t known yet. Reload the order.")
        }
        total = print + delivery
    } else {
        total = nil
    }
    guard let total, total >= 0 else { return unusable }
    return .amount(roundedToCents(total))
}

/// Most units one sale can be entered as; anything above is almost certainly a typo.
let profitUnitsSoldLimit = 10_000

/// Parses the typed number of units sold (a whole number from 1 to `profitUnitsSoldLimit`), for per-unit listing fees.
/// It's typed rather than read from the Slant order, whose item quantities count every print and packing slip per
/// unit, not marketplace units.
func parseProfitUnitsSold(_ text: String) -> Int? {
    let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !value.isEmpty, value.count <= 6, value.allSatisfy({ $0.isASCII && $0.isNumber }),
          let units = Int(value), (1...profitUnitsSoldLimit).contains(units) else { return nil }
    return units
}

// MARK: Maths

struct ProfitLine: Equatable {
    let label: String
    /// Signed: revenue is positive, fees and the Slant total are negative.
    let amount: Decimal
}

struct ProfitCheckResult: Equatable {
    let lines: [ProfitLine]
    let revenue: Decimal
    let fees: Decimal
    let slantTotal: Decimal
    let profit: Decimal
    /// Estimated profit as a percentage of revenue, to one decimal place. Nil when revenue is zero.
    let marginPercent: Decimal?
}

private func percent(_ rate: Decimal, of base: Decimal) -> Decimal {
    roundedToCents(base * rate / 100)
}

/// revenue − marketplace fees − Slant total = profit. Each fee is rounded to the cent as marketplaces charge it.
/// Percentage fees apply to item + shipping (Etsy also charges processing on sales tax it collects; taxes are out of
/// scope here). The fixed processing fee is charged once per order with a sale; the listing fee once per unit sold
/// (at least one). Offsite Ads is capped at $100.
func profitCheck(itemTotal: Decimal, shippingCharged: Decimal, preset: ProfitFeePreset, rates: ProfitFeeRates,
                 offsiteAds: Bool, unitsSold: Int, slantTotal: Decimal) -> ProfitCheckResult {
    let item = roundedToCents(max(0, itemTotal))
    let shipping = roundedToCents(max(0, shippingCharged))
    let revenue = item + shipping
    var lines = [ProfitLine(label: "Item total paid", amount: item), ProfitLine(label: "Shipping charged", amount: shipping)]
    var fees: Decimal = 0
    func fee(_ label: String, _ amount: Decimal) {
        guard amount > 0 else { return }
        fees += amount
        lines.append(ProfitLine(label: label, amount: -amount))
    }
    if preset.hasRates, revenue > 0 {
        fee("Transaction fee (\(profitRateText(rates.transactionPercent))%)", percent(rates.transactionPercent, of: revenue))
        let processing = percent(rates.processingPercent, of: revenue) + roundedToCents(rates.processingFixed)
        fee("Payment processing (\(profitRateText(rates.processingPercent))% + \(money(NSDecimalNumber(decimal: rates.processingFixed))))", processing)
        let units = max(1, unitsSold)
        fee("Listing fees (\(units) × \(money(NSDecimalNumber(decimal: rates.listingFeePerItem))))", roundedToCents(rates.listingFeePerItem * Decimal(units)))
        if offsiteAds, preset.offersOffsiteAds {
            fee("Offsite Ads (\(profitRateText(rates.offsiteAdsPercent))%, max $100)", min(percent(rates.offsiteAdsPercent, of: revenue), etsyOffsiteAdsCap))
        }
    }
    let slant = roundedToCents(slantTotal)
    lines.append(ProfitLine(label: "Slant order total", amount: -slant))
    let profit = revenue - fees - slant
    var margin: Decimal?
    if revenue > 0 {
        var raw = profit / revenue * 100
        var rounded = Decimal()
        NSDecimalRound(&rounded, &raw, 1, .plain)
        margin = rounded
    }
    return ProfitCheckResult(lines: lines, revenue: revenue, fees: fees, slantTotal: slant, profit: profit, marginPercent: margin)
}

/// "$12.34" or "−$12.34" for a signed amount.
func profitMoney(_ amount: Decimal) -> String {
    amount < 0 ? "−" + money(NSDecimalNumber(decimal: -amount)) : money(NSDecimalNumber(decimal: amount))
}

let profitCheckExclusionsNote = "Not included: taxes, refunds, ads you pay for separately, currency conversion."

/// One dated line for the fee rates in use, such as "Etsy (US): 6.5% transaction + 3% + $0.25 processing +
/// $0.20/unit listing · checked October 2026". Only fees that apply and aren't zero are listed, each named;
/// Offsite Ads only when this sale came from one. Edited preset rates say so, keeping the preset's checked date.
func profitFeeRatesSummary(preset: ProfitFeePreset, rates: ProfitFeeRates, offsiteAds: Bool) -> String {
    guard preset.hasRates else { return preset.title }
    func usd(_ value: Decimal) -> String { money(NSDecimalNumber(decimal: value)) }
    var parts: [String] = []
    if preset != .shopifyBasicUS, rates.transactionPercent > 0 {
        parts.append("\(profitRateText(rates.transactionPercent))% transaction")
    }
    // Payment processing's percentage and fixed fee read as one named fee: "3% + $0.25 processing".
    var processing: [String] = []
    if rates.processingPercent > 0 { processing.append("\(profitRateText(rates.processingPercent))%") }
    if rates.processingFixed > 0 { processing.append(usd(rates.processingFixed)) }
    if !processing.isEmpty { parts.append(processing.joined(separator: " + ") + " processing") }
    if preset != .shopifyBasicUS, rates.listingFeePerItem > 0 { parts.append("\(usd(rates.listingFeePerItem))/unit listing") }
    if offsiteAds, preset.offersOffsiteAds, rates.offsiteAdsPercent > 0 {
        parts.append("\(profitRateText(rates.offsiteAdsPercent))% Offsite Ads (max $100)")
    }
    let fees = parts.isEmpty ? "no fees entered" : parts.joined(separator: " + ")
    let dated: String
    if preset == .custom {
        dated = "your rates"
    } else if rates == preset.defaultRates {
        dated = "checked \(profitFeeRatesCheckedDate)"
    } else {
        dated = "your rates (preset checked \(profitFeeRatesCheckedDate))"
    }
    return "\(preset.title): \(fees) · \(dated)"
}

/// Whether the rate editor must be open: a rate is invalid, or a Custom preset has no fees yet. The panel latches the
/// editor open when this is true, so it never closes by itself while the user types.
func profitRateEditorNeedsAttention(preset: ProfitFeePreset, ratesValid: Bool, currentRates: ProfitFeeRates) -> Bool {
    guard preset.hasRates else { return false }
    return !ratesValid || (preset == .custom && currentRates == ProfitFeeRates())
}

// MARK: Saved fee settings (rates and preset only)

enum ProfitFeeSettings {
    static let presetKey = "profitCheck.preset"
    static func ratesKey(_ preset: ProfitFeePreset) -> String { "profitCheck.rates.\(preset.rawValue)" }

    static func loadPreset(_ defaults: UserDefaults = .standard) -> ProfitFeePreset {
        defaults.string(forKey: presetKey).flatMap(ProfitFeePreset.init(rawValue:)) ?? .none
    }
    /// Saved rates for the preset, falling back to its defaults for any missing or invalid value.
    static func loadRates(_ preset: ProfitFeePreset, _ defaults: UserDefaults = .standard) -> ProfitFeeRates {
        var rates = preset.defaultRates
        guard let saved = defaults.dictionary(forKey: ratesKey(preset)) as? [String: String] else { return rates }
        for field in ProfitRateField.allCases {
            guard let text = saved[field.rawValue] else { continue }
            let parsed = field.isPercent ? parseProfitPercent(text, decimalSeparator: ".") : parseProfitAmount(text, decimalSeparator: ".")
            if let parsed { rates[field] = parsed }
        }
        return rates
    }
    static func save(preset: ProfitFeePreset, rates: ProfitFeeRates, _ defaults: UserDefaults = .standard) {
        defaults.set(preset.rawValue, forKey: presetKey)
        guard preset.hasRates else { return }
        var values: [String: String] = [:]
        for field in ProfitRateField.allCases { values[field.rawValue] = profitRateText(rates[field]) }
        defaults.set(values, forKey: ratesKey(preset))
    }
    static func resetRates(_ preset: ProfitFeePreset, _ defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: ratesKey(preset))
    }
}

// MARK: - Panel

/// Collapsed-by-default profit check for one order. Give it `.id(orderID)` so typed amounts never carry over to
/// another order.
struct ProfitCheckPanel: View {
    let order: [String: Any]
    @State private var expanded = false
    @State private var itemText = ""
    @State private var shippingText = ""
    @State private var preset = ProfitFeeSettings.loadPreset()
    @State private var rateTexts: [ProfitRateField: String] = [:]
    /// Whether this sale came from an ad is a fact about this order, so it starts off and isn't saved.
    @State private var offsiteAds = false
    /// Marketplace units sold, for the per-unit listing fee. Like the amounts paid, a fact about this sale: not saved.
    @State private var unitsText = "1"
    @State private var loadedRates = false
    @State private var ratesExpanded = false

    var body: some View {
        DisclosureGroup("Profit check", isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 10) {
                switch profitCheckSlantTotal(order) {
                case .unavailable(let reason):
                    Text(reason).font(.callout).foregroundStyle(.secondary)
                case .amount(let slantTotal):
                    content(slantTotal: slantTotal)
                }
            }
            // Inputs and results line up in one right-aligned column, like a receipt.
            .labeledContentStyle(.receipt)
            .padding(.top, 6)
        }.studioDisclosureStyle()
        .onAppear(perform: loadRatesIfNeeded)
    }

    @ViewBuilder
    func content(slantTotal: Decimal) -> some View {
        Text("Enter what the buyer paid, in US dollars. Slant charges in USD; if you sold in another currency, convert it first. Nothing you type here is saved.")
            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        moneyField("Item total paid", text: $itemText)
        moneyField("Shipping charged", text: $shippingText)
        LabeledContent {
            // The menu may shorten a long preset name in a narrow pane; the label never breaks mid-word.
            Picker("Marketplace fees", selection: Binding(get: { preset }, set: { choosePreset($0) })) {
                ForEach(ProfitFeePreset.allCases) { Text($0.title).tag($0) }
            }
            .labelsHidden()
            .frame(maxWidth: 260)
        } label: {
            Text("Marketplace fees").fixedSize()
        }
        if preset.hasRates { rateFields }
        Divider()
        resultView(slantTotal: slantTotal)
    }

    @ViewBuilder
    func moneyField(_ title: String, text: Binding<String>) -> some View {
        LabeledContent(title) {
            HStack(spacing: 4) {
                Text("$").foregroundStyle(.secondary)
                TextField(title, text: text, prompt: Text("0.00")).labelsHidden().accessibilityLabel(title).frame(width: 110).multilineTextAlignment(.trailing)
            }
        }
    }

    /// The rate editor opens on request, and stays open while a rate is invalid or a Custom preset has no fees yet.
    var rateEditorExpanded: Binding<Bool> {
        Binding(get: { ratesExpanded || rateEditorNeedsAttention }, set: { ratesExpanded = $0 })
    }
    var rateEditorNeedsAttention: Bool {
        profitRateEditorNeedsAttention(preset: preset, ratesValid: validRates != nil, currentRates: currentRates)
    }
    /// Once the editor has opened by itself it stays open (until the user closes it), so fixing a rate or typing the
    /// first Custom fee doesn't collapse it mid-edit.
    func latchRateEditorIfNeeded() {
        if rateEditorNeedsAttention { ratesExpanded = true }
    }

    @ViewBuilder
    var rateFields: some View {
        VStack(alignment: .leading, spacing: 6) {
            // One dated line instead of every rate; the rates stay editable below.
            Text(validRates.map { profitFeeRatesSummary(preset: preset, rates: $0, offsiteAds: offsiteAds) }
                 ?? "\(preset.title): check the highlighted rates.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            DisclosureGroup("Edit rates", isExpanded: rateEditorExpanded) {
                VStack(alignment: .leading, spacing: 6) {
                    if preset != .custom {
                        Text("Assumed rates. Check your own account and edit them if yours differ.")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    if preset != .shopifyBasicUS { rateField(.transactionPercent, "Transaction fee (% of item + shipping)") }
                    rateField(.processingPercent, "Payment processing (%)")
                    rateField(.processingFixed, "Payment processing ($ per order)")
                    if showsListingFee { rateField(.listingFeePerItem, "Listing fee ($ per unit sold)") }
                    if preset.offersOffsiteAds { rateField(.offsiteAdsPercent, "Offsite Ads fee (%, max $100)") }
                    if preset != .custom, currentRates != preset.defaultRates || rateTexts.values.contains(where: { $0.isEmpty }) {
                        Button("Restore \(preset.title) Rates") { restoreDefaults() }.controlSize(.small)
                    }
                }
                .padding(.top, 4)
            }.studioDisclosureStyle()
            if showsListingFee {
                LabeledContent("Units sold") {
                    VStack(alignment: .trailing, spacing: 2) {
                        TextField("Units sold", text: $unitsText).labelsHidden().accessibilityLabel("Units sold").frame(width: 80).multilineTextAlignment(.trailing)
                        if parseProfitUnitsSold(unitsText) == nil {
                            Text("Enter a whole number from 1").font(.caption2).foregroundStyle(.orange)
                        }
                    }
                }
                .help("How many units the buyer bought on the marketplace, not the number of prints in the Slant order")
            }
            if preset.offersOffsiteAds {
                Toggle("This sale came from Offsite Ads", isOn: $offsiteAds)
            }
        }
    }

    @ViewBuilder
    func rateField(_ field: ProfitRateField, _ title: String) -> some View {
        let binding = Binding(get: { rateTexts[field] ?? "" }, set: {
            latchRateEditorIfNeeded()
            rateTexts[field] = $0
            persist()
            latchRateEditorIfNeeded()
        })
        LabeledContent(title) {
            VStack(alignment: .trailing, spacing: 2) {
                TextField(title, text: binding).labelsHidden().accessibilityLabel(title).frame(width: 80).multilineTextAlignment(.trailing)
                if rateValue(field) == nil {
                    Text(field.isPercent ? "Enter 0–100" : "Enter an amount").font(.caption2).foregroundStyle(.orange)
                }
            }
        }
    }

    @ViewBuilder
    func resultView(slantTotal: Decimal) -> some View {
        if itemText.trimmingCharacters(in: .whitespaces).isEmpty {
            Text("Enter the item total to see the estimated profit.").font(.callout).foregroundStyle(.secondary)
        } else if let item = parseProfitAmount(itemText), let shipping = shippingAmount, let rates = validRates, let units = unitsSold {
            let result = profitCheck(itemTotal: item, shippingCharged: shipping, preset: preset, rates: rates, offsiteAds: offsiteAds,
                                     unitsSold: units, slantTotal: slantTotal)
            ForEach(Array(result.lines.enumerated()), id: \.offset) { _, line in
                LabeledContent(line.label) { Text(profitMoney(line.amount)).monospacedDigit() }.font(.callout)
            }
            LabeledContent("Estimated profit") {
                Text(profitMoney(result.profit)).monospacedDigit().fontWeight(.semibold)
                    .foregroundStyle(result.profit < 0 ? .red : .primary)
            }
            if let margin = result.marginPercent {
                LabeledContent("Estimated margin") { Text("\(profitRateText(margin))%").monospacedDigit() }
            }
            if (order["status"] as? String)?.uppercased() == "DRAFT" {
                Text("This draft’s total is Slant’s current price; it’s charged when you place the order.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text(profitCheckExclusionsNote).font(.caption).foregroundStyle(.secondary)
        } else if unitsSold == nil, parseProfitAmount(itemText) != nil, shippingAmount != nil, validRates != nil {
            Text("Enter the units sold as a whole number, such as 1.").font(.callout).foregroundStyle(.orange)
        } else {
            Text("Check the highlighted amounts: use numbers like 24.99.").font(.callout).foregroundStyle(.orange)
        }
    }

    var shippingAmount: Decimal? {
        shippingText.trimmingCharacters(in: .whitespaces).isEmpty ? 0 : parseProfitAmount(shippingText)
    }
    /// Etsy and Custom have a per-unit listing fee; Shopify Payments doesn't.
    var showsListingFee: Bool { preset.hasRates && preset != .shopifyBasicUS }
    /// Units typed for the listing fee; 1 when the fee isn't shown, so a hidden field can't block the result.
    var unitsSold: Int? { showsListingFee ? parseProfitUnitsSold(unitsText) : 1 }
    func rateValue(_ field: ProfitRateField) -> Decimal? {
        let text = rateTexts[field] ?? ""
        return field.isPercent ? parseProfitPercent(text) : parseProfitAmount(text)
    }
    /// Rates as typed; nil when any shown field is invalid.
    var validRates: ProfitFeeRates? {
        var rates = ProfitFeeRates()
        for field in ProfitRateField.allCases {
            guard let value = rateValue(field) else { return preset.hasRates ? nil : rates }
            rates[field] = value
        }
        return rates
    }
    /// Rates as typed, with invalid fields falling back to the preset default (for the restore button).
    var currentRates: ProfitFeeRates {
        var rates = preset.defaultRates
        for field in ProfitRateField.allCases { if let value = rateValue(field) { rates[field] = value } }
        return rates
    }

    func loadRatesIfNeeded() {
        guard !loadedRates else { return }
        loadedRates = true
        fillRateTexts(ProfitFeeSettings.loadRates(preset))
        latchRateEditorIfNeeded()
    }
    func fillRateTexts(_ rates: ProfitFeeRates) {
        let separator = Locale.current.decimalSeparator ?? "."
        var texts: [ProfitRateField: String] = [:]
        for field in ProfitRateField.allCases {
            var text = profitRateText(rates[field])
            if separator == "," { text = text.replacingOccurrences(of: ".", with: ",") }
            texts[field] = text
        }
        rateTexts = texts
    }
    func choosePreset(_ newPreset: ProfitFeePreset) {
        preset = newPreset
        fillRateTexts(ProfitFeeSettings.loadRates(newPreset))
        persist()
        latchRateEditorIfNeeded()
    }
    func restoreDefaults() {
        ProfitFeeSettings.resetRates(preset)
        fillRateTexts(preset.defaultRates)
        persist()
    }
    /// Saves the preset and only valid rates; never what the buyer paid.
    func persist() {
        ProfitFeeSettings.save(preset: preset, rates: currentRates)
    }
}
