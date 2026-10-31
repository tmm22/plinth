import Foundation

// Read-only tools over loaded 3DAPI orders: Needs Attention, the Profit check's order cost, Report a Problem, Export
// Orders, the Spending Report (and its Load the Whole Period), and Tracking for Your Shop. Everything here is worked
// out from orders already read; the only requests are Load the Whole Period's read-only list pages. Nothing is saved:
// customer details, amounts and tracking stay in memory, and only what the seller copies or exports leaves the app.
// See docs/3DAPI_REFERENCE.md §6 (money) and §7 (orders). 3DAPI orders are never mixed with Slant's.

// MARK: - Needs attention

/// 3DAPI's Business guide says orders ship within 3–5 business days of payment (a wallet order is paid when it is
/// placed). A paid order that hasn't reached production after this many business days looks stuck waiting for a
/// partner.
let dapiAttentionNotStartedBusinessDays = 3
/// An order still not shipped this many business days after it was placed: the guide's 5 business days from payment
/// to shipping, plus 2 days' margin.
let dapiAttentionNotShippedBusinessDays = 7
/// Business days are counted at most this far (a year of weekdays); older orders count as this many.
let dapiAttentionBusinessDayCountLimit = 260

/// Why a 3DAPI order needs a look. Worked out locally from the loaded order and the clock; never a request.
enum DapiOrderAttention: Equatable {
    case onHold
    case rejected
    case returned
    /// Paid or assigned, not in production, this many business days after it was placed.
    case notStarted(businessDays: Int)
    /// In production (or later stages before shipping), not shipped this many business days after it was placed.
    case notShipped(businessDays: Int)
    case unrecognisedStatus(String)

    /// Short text for a list marker.
    var title: String {
        switch self {
        case .onHold: return "On hold"
        case .rejected: return "Rejected"
        case .returned: return "Returned"
        case .notStarted: return "Not started"
        case .notShipped: return "Not shipped"
        case .unrecognisedStatus: return "Unrecognised status"
        }
    }

    /// One sentence for the detail, a marker's tooltip and VoiceOver.
    var detail: String {
        switch self {
        case .onHold:
            return "On hold: 3DAPI is waiting for stock to make it."
        case .rejected:
            return "A production partner refused it; 3DAPI will reassign it, or cancel and refund it."
        case .returned:
            return "It was sent back after shipping. Contact 3DAPI if you didn’t expect this."
        case .notStarted(let days):
            return "Production hasn’t started \(dapiBusinessDaysText(days)) after it was placed."
        case .notShipped(let days):
            return "Not shipped \(dapiBusinessDaysText(days)) after it was placed; 3DAPI says orders ship within 3–5 business days of payment."
        case .unrecognisedStatus(let word):
            return "3DAPI sent a status Plinth doesn’t recognise (\(dapiOrderStatusWordForDisplay(word)))."
        }
    }
}

func dapiBusinessDaysText(_ days: Int) -> String { days == 1 ? "1 business day" : "\(days) business days" }

/// A status word as shown: trimmed, at most 40 characters, letters, digits, `_` and `-` only.
func dapiOrderStatusWordForDisplay(_ word: String) -> String {
    let cleaned = String(word.trimmingCharacters(in: .whitespacesAndNewlines).unicodeScalars
        .filter { CharacterSet.alphanumerics.contains($0) || $0 == "_" || $0 == "-" }.prefix(40).map(Character.init))
    return cleaned.isEmpty ? "blank" : cleaned
}

/// Weekdays (by `calendar`'s weekend) after `start`'s day, up to and including `end`'s day: an order placed on a
/// Monday is 3 business days old on Thursday. 0 when `end` is not after `start`. Counts at most `limit`.
func dapiBusinessDays(from start: Date, to end: Date, calendar: Calendar = .current,
                      limit: Int = dapiAttentionBusinessDayCountLimit) -> Int {
    let first = calendar.startOfDay(for: start)
    let last = calendar.startOfDay(for: end)
    guard last > first else { return 0 }
    var count = 0
    var day = first
    // A year of weekdays is about 366 calendar days; the walk stops well before then once `limit` is reached.
    for _ in 0..<(limit * 2 + 14) {
        guard let next = calendar.date(byAdding: .day, value: 1, to: day), next <= last else { break }
        day = next
        if !calendar.isDateInWeekend(day) {
            count += 1
            if count >= limit { break }
        }
    }
    return count
}

/// The most pressing reason the order needs a look, or nil. Read-only and display only: it never enables anything.
/// Never for cancelled, completed, shipped or awaiting-payment orders; a returned order is always flagged. The time
/// rules use `createdAt` (a wallet order is paid when it is created) and need it.
func dapiOrderAttentionReason(_ order: DapiOrder, now: Date = Date(), calendar: Calendar = .current) -> DapiOrderAttention? {
    switch order.status {
    case .cancelled, .completed, .shipped, .awaitingPayment:
        return nil
    case .onHold:
        return .onHold
    case .rejected:
        return .rejected
    case .returned:
        return .returned
    case .unknown(let word):
        return .unrecognisedStatus(word)
    case .paid, .assigned, .inProduction:
        guard let created = order.createdAt, created < now else { return nil }
        let days = dapiBusinessDays(from: created, to: now, calendar: calendar)
        if days > dapiAttentionNotShippedBusinessDays { return .notShipped(businessDays: days) }
        if order.status != .inProduction, days > dapiAttentionNotStartedBusinessDays { return .notStarted(businessDays: days) }
        return nil
    }
}

/// Why this order needs the seller's attention now, or nil. Read-only, display only.
func dapiOrderAttention(_ order: DapiOrder, now: Date = Date()) -> String? {
    dapiOrderAttentionReason(order, now: now)?.detail
}

// MARK: - The order's cost (Profit check)

enum DapiOrderCost: Equatable {
    case amount(Decimal)
    case unavailable(String)
}

/// What the order cost the seller in USD: `charges.total` (VAT included, before sample credit) less the sample credit
/// and completed refunds. Only for placed orders paid from the seller's own 3DAPI account (`paid_by` "you") whose
/// amounts are all USD; otherwise why there's no figure. Strict: nothing is guessed or converted.
func dapiOrderCost(_ order: DapiOrder) -> DapiOrderCost {
    switch order.status {
    case .cancelled:
        return .unavailable("This order was cancelled, so there’s no sale to check.")
    case .awaitingPayment:
        return .unavailable("This order hasn’t been paid for yet, so 3DAPI hasn’t charged anything.")
    case .unknown:
        return .unavailable("3DAPI sent a status Plinth doesn’t recognise, so it can’t tell what this order cost.")
    default:
        break
    }
    guard let charges = order.charges else {
        return .unavailable("3DAPI hasn’t returned this order’s charges. Reload it to try again.")
    }
    let paidBy = charges.paidBy.trimmingCharacters(in: .whitespaces).lowercased()
    if paidBy == "dapi" {
        return .unavailable("3DAPI covered this order (a replacement), so you weren’t charged.")
    }
    guard paidBy == "you" else {
        return .unavailable("This order wasn’t paid from your 3DAPI balance (3DAPI says it was paid by “\(dapiOrderStatusWordForDisplay(charges.paidBy))”), so there’s no cost to you to check.")
    }
    var amounts = [charges.total]
    if let credit = charges.sampleCredit { amounts.append(credit) }
    amounts += order.refunds.map(\.amount)
    if let other = amounts.first(where: { $0.usd == nil }) {
        let code = other.currency.trimmingCharacters(in: .whitespaces).uppercased()
        return .unavailable("3DAPI returned this order’s charges in \(code.isEmpty ? "an unknown currency" : code), and the profit check only works in USD.")
    }
    guard amounts.allSatisfy({ $0.amountMinor >= 0 }), let total = charges.total.usd else {
        return .unavailable("3DAPI returned amounts for this order that Plinth can’t read. Check it in 3DAPI’s dashboard.")
    }
    let credit = charges.sampleCredit?.usd ?? 0
    let refunds = order.refunds.compactMap(\.amount.usd).reduce(Decimal(0), +)
    let cost = total - credit - refunds
    guard cost >= 0 else {
        return .unavailable("This order’s sample credit and refunds add up to more than 3DAPI charged, so Plinth can’t work out its cost. Check it in 3DAPI’s dashboard.")
    }
    return .amount(roundedToCents(cost))
}

/// The Profit check's caption for 3DAPI.
let dapiProfitCheckEntryCaption = "Enter what the buyer paid, in US dollars. 3DAPI charges in USD; if you sold in another currency, convert it first. Nothing you type here is saved, and it clears when you choose another order."

/// The receipt's last line for 3DAPI's cost (Margin.swift's `profitCheck` names Slant).
let dapiProfitCostLineLabel = "3DAPI order cost"

/// `profitCheck` with its Slant line renamed for 3DAPI. The maths and fee rules are Margin.swift's own.
func dapiProfitCheck(itemTotal: Decimal, shippingCharged: Decimal, preset: ProfitFeePreset, rates: ProfitFeeRates,
                     offsiteAds: Bool, unitsSold: Int, orderCost: Decimal) -> ProfitCheckResult {
    let result = profitCheck(itemTotal: itemTotal, shippingCharged: shippingCharged, preset: preset, rates: rates,
                             offsiteAds: offsiteAds, unitsSold: unitsSold, slantTotal: orderCost)
    var lines = result.lines
    if let last = lines.indices.last { lines[last] = ProfitLine(label: dapiProfitCostLineLabel, amount: lines[last].amount) }
    return ProfitCheckResult(lines: lines, revenue: result.revenue, fees: result.fees, slantTotal: result.slantTotal,
                             profit: result.profit, marginPercent: result.marginPercent)
}

/// A note under the profit figures when the cost may still change, or nil.
func dapiProfitCostNote(_ order: DapiOrder) -> String? {
    switch order.status {
    case .rejected, .onHold, .returned:
        return "3DAPI may still refund some or all of this order; reload it later for the final cost."
    default:
        return order.refunds.isEmpty ? nil : "Refunds 3DAPI has completed are taken off the cost."
    }
}

// MARK: - Report a Problem

enum DapiProblemKind: String, CaseIterable, Identifiable {
    case lostParcel, damaged, printDefect, wrongItem, missingItem, late, cancel, refund, other
    var id: String { rawValue }
    var title: String {
        switch self {
        case .lostParcel: return "Lost parcel"
        case .damaged: return "Damaged item"
        case .printDefect: return "Print defect"
        case .wrongItem: return "Wrong item"
        case .missingItem: return "Missing item"
        case .late: return "Late order"
        case .cancel: return "Cancel the order"
        case .refund: return "Refund not received"
        case .other: return "Other"
        }
    }
}

/// 3DAPI's address for order problems (its docs and business guide).
let dapiProblemSupportAddress = "contact@dapi.digital"
let dapiProblemReportCaption = "Plinth puts together a message with this order’s details for you to send to 3DAPI (\(dapiProblemSupportAddress)). It doesn’t send anything itself: copy the message and paste it into your email. Names and addresses aren’t included."

/// The problems that fit the order's status, "Other" last and always offered.
func dapiProblemKinds(status: DapiOrderStatus) -> [DapiProblemKind] {
    var kinds: [DapiProblemKind] = []
    switch status {
    case .shipped:
        kinds = [.lostParcel, .damaged, .printDefect, .wrongItem, .missingItem, .late]
    case .completed, .returned:
        kinds = [.lostParcel, .damaged, .printDefect, .wrongItem, .missingItem]
    case .paid:
        // Cancel is offered in Plinth itself while the order is `paid` (the orders screen's own review).
        kinds = [.late]
    case .assigned, .inProduction, .onHold:
        kinds = [.late, .cancel]
    case .rejected:
        kinds = [.late, .cancel, .refund]
    case .cancelled:
        kinds = [.refund]
    case .awaitingPayment, .unknown:
        kinds = []
    }
    return kinds + [.other]
}

/// What 3DAPI says about this kind of problem, shown under the caption; nil when there's nothing particular.
func dapiProblemGuidance(_ kind: DapiProblemKind) -> String? {
    switch kind {
    case .lostParcel:
        return "3DAPI says it reprints lost parcels free of charge."
    case .damaged, .printDefect, .wrongItem:
        return "3DAPI asks for photos of the problem: attach them to your email."
    case .cancel:
        return "Once a production partner has the order, 3DAPI can cancel it only by email, and may not be able to."
    case .refund:
        return "3DAPI refunds wallet orders to your 3DAPI wallet, and checkout orders to your customer’s card within 5–10 business days."
    case .missingItem, .late, .other:
        return nil
    }
}

/// The support message: order number, status, created date, carrier and tracking, items with quantities and
/// materials, the problem and the seller's description. Never the customer's name, email or address, or the reference.
func dapiProblemMessage(order: DapiOrder, problem: DapiProblemKind, details: String, timeZone: TimeZone = .current) -> String {
    let number = order.number.trimmingCharacters(in: .whitespacesAndNewlines)
    let subject = number.isEmpty ? "my order" : "order \(number)"
    var lines = ["Hello 3DAPI team,", "", "I’d like to report a problem with \(subject): \(problem.title.lowercased()).", ""]
    if !number.isEmpty { lines.append("Order number: \(number)") }
    lines.append("Status: \(order.status.label)" + (order.status.isUnknown ? " (\(dapiOrderStatusWordForDisplay(order.status.raw)))" : ""))
    if let created = order.createdAt { lines.append("Created: \(dapiProblemDateText(created, timeZone: timeZone))") }
    if let carrier = dapiNonEmpty(order.shipping.carrier) { lines.append("Carrier: \(carrier)") }
    if let tracking = dapiNonEmpty(order.shipping.trackingNumber) { lines.append("Tracking number: \(tracking)") }
    if let shipped = order.shipping.shippedAt { lines.append("Shipped: \(dapiProblemDateText(shipped, timeZone: timeZone))") }
    lines.append("Problem: \(problem.title)")
    if let items = order.items, !items.isEmpty {
        lines.append("")
        lines.append("Items:")
        for item in items {
            var text = "- \(item.quantity) × " + (dapiNonEmpty(item.quoteName) ?? "Quote \(item.quoteID)")
            let materials = item.materials.compactMap { dapiNonEmpty($0.materialName) }
            if !materials.isEmpty { text += " (\(materials.joined(separator: ", ")))" }
            lines.append(text)
        }
    }
    let description = details.trimmingCharacters(in: .whitespacesAndNewlines)
    if !description.isEmpty {
        lines.append("")
        lines.append("What happened:")
        lines.append(description)
    }
    if [.damaged, .printDefect, .wrongItem].contains(problem) {
        lines.append("")
        lines.append("I’ve attached photos.")
    }
    lines.append("")
    lines.append("Thank you.")
    return lines.joined(separator: "\n")
}

/// The Report a Problem… button is offered once an order has been paid for (or for an unrecognised status, as Other).
func dapiOffersProblemReport(status: DapiOrderStatus) -> Bool { status != .awaitingPayment }

/// "31 October 2026" in the Mac's time zone, in English (the message is written in English).
func dapiProblemDateText(_ date: Date, timeZone: TimeZone = .current) -> String {
    let formatter = DateFormatter()
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.locale = Locale(identifier: "en_GB")
    formatter.timeZone = timeZone
    formatter.dateFormat = "d MMMM yyyy"
    return formatter.string(from: date)
}

func dapiNonEmpty(_ text: String?) -> String? {
    guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
    return trimmed
}

// MARK: - Export Orders (CSV)

let dapiOrdersCSVBaseColumns = ["Order number", "Status", "Created", "Updated", "Reference", "Country", "Units", "Items",
                                "Shipping", "VAT", "Sample credit", "Refunds", "Total", "Currency", "Carrier", "Tracking number"]
let dapiOrdersCSVCustomerColumns = ["Customer name", "Customer email", "Address", "City", "Country name"]

private let dapiCSVDateFormatter: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    formatter.timeZone = TimeZone(identifier: "UTC")
    return formatter
}()

/// A plain decimal for a CSV cell in the amount's own currency ("12.34"), never grouped or localised. Blank for a
/// currency code Plinth can't read, rather than a guess at its decimal places.
func dapiCSVAmount(_ value: DapiMoney?) -> String {
    guard let value else { return "" }
    let code = value.currency.trimmingCharacters(in: .whitespaces).uppercased()
    guard code.count == 3, code.allSatisfy({ $0.isASCII && $0.isLetter }) else { return "" }
    let digits: Int
    if code == "USD" {
        digits = 2
    } else {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currencyISOCode
        formatter.currencyCode = code
        digits = max(0, formatter.maximumFractionDigits)
    }
    var divisor = Decimal(1)
    for _ in 0..<digits { divisor *= 10 }
    let formatter = NumberFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.numberStyle = .decimal
    formatter.usesGroupingSeparator = false
    formatter.minimumFractionDigits = digits
    formatter.maximumFractionDigits = digits
    return formatter.string(from: NSDecimalNumber(decimal: Decimal(value.amountMinor) / divisor)) ?? ""
}

/// Units in the order (the lines' quantities), or nil when its lines weren't read.
func dapiOrderUnits(_ order: DapiOrder) -> Int? {
    guard let items = order.items else { return nil }
    var total = 0
    for item in items {
        let (sum, overflow) = total.addingReportingOverflow(max(0, item.quantity))
        if overflow { return nil }
        total = sum
    }
    return total
}

/// Completed refunds summed in `currency`; nil when any refund is in another currency (never added across currencies).
func dapiRefundTotal(_ order: DapiOrder, currency: String) -> DapiMoney? {
    var total = DapiMoney(amountMinor: 0, currency: currency)
    for refund in order.refunds {
        guard let sum = dapiMoneySum(total, refund.amount) else { return nil }
        total = sum
    }
    return total
}

/// One CSV row in `dapiOrdersCSVBaseColumns` (+ customer columns) order. Amounts in another currency than the total
/// are left blank rather than mixed. Fields 3DAPI didn't return are blank; nothing is estimated.
func dapiOrdersCSVRow(_ order: DapiOrder, includeCustomer: Bool) -> [String] {
    let charges = order.charges
    let currency = charges?.total.currency.lowercased() ?? ""
    func sameCurrency(_ value: DapiMoney?) -> DapiMoney? {
        guard let value, value.currency.lowercased() == currency else { return nil }
        return value
    }
    let refunds: String
    if charges == nil {
        refunds = ""
    } else {
        refunds = dapiCSVAmount(dapiRefundTotal(order, currency: currency))
    }
    var row = [
        order.number, order.status.raw,
        order.createdAt.map { dapiCSVDateFormatter.string(from: $0) } ?? "",
        order.updatedAt.map { dapiCSVDateFormatter.string(from: $0) } ?? "",
        // The seller's part only, without Plinth's per-attempt code (`dapiOrderSellerReference`).
        dapiOrderSellerReference(order.reference) ?? "", order.countryCode?.uppercased() ?? "",
        dapiOrderUnits(order).map(String.init) ?? "",
        dapiCSVAmount(sameCurrency(charges?.items)), dapiCSVAmount(sameCurrency(charges?.shipping)),
        dapiCSVAmount(sameCurrency(charges?.vat)), dapiCSVAmount(sameCurrency(charges?.sampleCredit)), refunds,
        dapiCSVAmount(charges?.total), currency.uppercased(),
        order.shipping.carrier ?? "", order.shipping.trackingNumber ?? ""
    ]
    if includeCustomer {
        row += [order.customerName ?? "", order.customerEmail ?? "", order.formattedAddress ?? "", order.city ?? "",
                order.countryName ?? ""]
    }
    return row.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
}

/// The CSV (header first, CRLF line endings) through `csvField`, which guards against formulas. Customer name,
/// email and address only when `includeCustomer`.
func dapiOrdersCSV(_ orders: [DapiOrder], includeCustomer: Bool) -> String {
    let header = includeCustomer ? dapiOrdersCSVBaseColumns + dapiOrdersCSVCustomerColumns : dapiOrdersCSVBaseColumns
    let rows = [header] + orders.map { dapiOrdersCSVRow($0, includeCustomer: includeCustomer) }
    return rows.map { $0.map(csvField).joined(separator: ",") }.joined(separator: "\r\n") + "\r\n"
}

func dapiDatedFileName(_ prefix: String, date: Date = Date(), timeZone: TimeZone = .current) -> String {
    let formatter = DateFormatter()
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = timeZone
    formatter.dateFormat = "yyyy-MM-dd"
    return "\(prefix) \(formatter.string(from: date)).csv"
}

// MARK: - Spending report

/// One local calendar month of counted orders, in USD.
struct DapiSpendMonth: Equatable, Identifiable {
    let year: Int
    let month: Int
    var orders = 0
    var units = 0
    /// Counted orders whose lines weren't read, so their units aren't in `units`.
    var ordersWithoutUnits = 0
    var items: Decimal = 0
    var shipping: Decimal = 0
    var vat: Decimal = 0
    var sampleCredit: Decimal = 0
    var refunds: Decimal = 0
    /// total − sample credit − refunds, summed.
    var totalPaid: Decimal = 0
    var id: String { String(format: "%04d-%02d", year, month) }
}

/// Shipping to one destination country across counted USD orders.
struct DapiSpendCountry: Equatable, Identifiable {
    let countryCode: String
    var orders = 0
    var totalShipping: Decimal = 0
    var lowest: Decimal?
    var highest: Decimal?
    var average: Decimal? {
        guard orders > 0 else { return nil }
        return roundedToCents(totalShipping / Decimal(orders))
    }
    var id: String { countryCode }
}

/// Counted orders charged in a currency other than USD: listed apart, never added to the USD figures.
struct DapiSpendOtherCurrency: Equatable, Identifiable {
    /// Upper-case code as sent.
    let currency: String
    var orders = 0
    /// total − sample credit − refunds, in minor units of `currency`; nil once a sum overflowed.
    var totalPaidMinor: Int? = 0
    var id: String { currency }
}

struct DapiSpendReport: Equatable {
    var months: [DapiSpendMonth] = []
    var countries: [DapiSpendCountry] = []
    var otherCurrencies: [DapiSpendOtherCurrency] = []
    /// USD orders counted in `months`.
    var countedOrders = 0
    var totalPaid: Decimal = 0
    var units = 0
    /// Left out: not placed (awaiting payment, cancelled) or an unrecognised status.
    var notPlaced = 0
    /// Left out: paid by the buyer or 3DAPI (checkout), not from the seller's balance.
    var notPaidByYou = 0
    /// Left out: 3DAPI returned no charges.
    var withoutCharges = 0
    /// Left out: amounts in more than one currency, negative, or credit and refunds above the total.
    var unreadableAmounts = 0
    /// Left out of the months: no creation date.
    var withoutDate = 0
    /// Counted USD orders without a recognisable destination country (left out of `countries` only).
    var withoutCountry = 0
}

/// The sum, or nil on overflow.
func dapiCheckedSum(_ values: [Int]) -> Int? {
    var total = 0
    for value in values {
        let (sum, overflow) = total.addingReportingOverflow(value)
        if overflow { return nil }
        total = sum
    }
    return total
}

/// The order's (year, month) on `calendar` (its time zone decides which month an order near midnight belongs to).
func dapiSpendMonthKey(_ date: Date, calendar: Calendar = .current) -> (year: Int, month: Int) {
    let parts = calendar.dateComponents([.year, .month], from: date)
    return (parts.year ?? 0, parts.month ?? 0)
}

/// The destination as an upper-case ISO alpha-2 code, or nil. Never guessed from a name.
func dapiSpendCountryCode(_ order: DapiOrder) -> String? {
    guard let code = order.countryCode?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased(),
          code.count == 2, code.allSatisfy({ $0.isASCII && $0.isLetter }) else { return nil }
    return code
}

/// The report over `orders` (each order once, by ID). Counted: placed (`countsAsPlaced`) and paid by "you". USD
/// orders go into months and countries; orders in one other currency are summed per currency apart; anything mixed or
/// unreadable is left out and counted. Months are the local calendar's, newest first.
func dapiSpendReport(_ orders: [DapiOrder], calendar: Calendar = .current) -> DapiSpendReport {
    var report = DapiSpendReport()
    var months: [String: DapiSpendMonth] = [:]
    var countries: [String: DapiSpendCountry] = [:]
    var others: [String: DapiSpendOtherCurrency] = [:]
    var seen = Set<String>()
    for order in orders where seen.insert(order.id).inserted {
        guard order.status.countsAsPlaced else { report.notPlaced += 1; continue }
        guard let charges = order.charges else { report.withoutCharges += 1; continue }
        guard charges.paidBy.trimmingCharacters(in: .whitespaces).lowercased() == "you" else { report.notPaidByYou += 1; continue }
        var amounts = [charges.items, charges.shipping, charges.vat, charges.total]
        if let credit = charges.sampleCredit { amounts.append(credit) }
        amounts += order.refunds.map(\.amount)
        let currency = charges.total.currency.trimmingCharacters(in: .whitespaces).lowercased()
        guard !currency.isEmpty, amounts.allSatisfy({ $0.currency.trimmingCharacters(in: .whitespaces).lowercased() == currency && $0.amountMinor >= 0 })
        else { report.unreadableAmounts += 1; continue }
        let creditMinor = charges.sampleCredit?.amountMinor ?? 0
        guard let refundMinor = dapiCheckedSum(order.refunds.map(\.amount.amountMinor)),
              let deductions = dapiCheckedSum([creditMinor, refundMinor]),
              charges.total.amountMinor >= deductions else { report.unreadableAmounts += 1; continue }
        let paidMinor = charges.total.amountMinor - deductions
        guard currency == "usd" else {
            let code = currency.uppercased()
            var entry = others[code] ?? DapiSpendOtherCurrency(currency: code)
            entry.orders += 1
            if let sum = entry.totalPaidMinor {
                let (added, overflow) = sum.addingReportingOverflow(paidMinor)
                entry.totalPaidMinor = overflow ? nil : added
            }
            others[code] = entry
            continue
        }
        guard let created = order.createdAt else { report.withoutDate += 1; continue }
        func usd(_ minor: Int) -> Decimal { Decimal(minor) / 100 }
        let key = dapiSpendMonthKey(created, calendar: calendar)
        let id = String(format: "%04d-%02d", key.year, key.month)
        var month = months[id] ?? DapiSpendMonth(year: key.year, month: key.month)
        month.orders += 1
        if let units = dapiOrderUnits(order) { month.units += units; report.units += units } else { month.ordersWithoutUnits += 1 }
        month.items += usd(charges.items.amountMinor)
        month.shipping += usd(charges.shipping.amountMinor)
        month.vat += usd(charges.vat.amountMinor)
        month.sampleCredit += usd(creditMinor)
        month.refunds += usd(refundMinor)
        month.totalPaid += usd(paidMinor)
        months[id] = month
        report.countedOrders += 1
        report.totalPaid += usd(paidMinor)
        if let code = dapiSpendCountryCode(order) {
            var country = countries[code] ?? DapiSpendCountry(countryCode: code)
            let shipping = usd(charges.shipping.amountMinor)
            country.orders += 1
            country.totalShipping += shipping
            country.lowest = min(country.lowest ?? shipping, shipping)
            country.highest = max(country.highest ?? shipping, shipping)
            countries[code] = country
        } else {
            report.withoutCountry += 1
        }
    }
    report.months = months.values.sorted { $0.id > $1.id }
    report.countries = countries.values.sorted { $0.orders != $1.orders ? $0.orders > $1.orders : $0.countryCode < $1.countryCode }
    report.otherCurrencies = others.values.sorted { $0.currency < $1.currency }
    return report
}

/// One line naming what was left out, or nil.
func dapiSpendExclusionLine(_ report: DapiSpendReport) -> String? {
    func phrase(_ count: Int, _ text: String) -> String? { count > 0 ? "\(count) \(text)" : nil }
    let parts = [
        phrase(report.notPlaced, "not paid for, cancelled or with an unrecognised status"),
        phrase(report.notPaidByYou, "paid by the buyer through 3DAPI’s checkout"),
        phrase(report.withoutCharges, "without charges"),
        phrase(report.unreadableAmounts, "with amounts Plinth can’t add up"),
        phrase(report.withoutDate, "without a date")
    ].compactMap { $0 }
    guard !parts.isEmpty else { return nil }
    let total = report.notPlaced + report.notPaidByYou + report.withoutCharges + report.unreadableAmounts + report.withoutDate
    return "Not included: " + parts.joined(separator: "; ") + (total == 1 ? " (1 order)." : " (\(total) orders).")
}

func dapiSpendMonthTitle(_ month: DapiSpendMonth, calendar: Calendar = .current) -> String {
    guard let date = calendar.date(from: DateComponents(year: month.year, month: month.month, day: 1)) else { return month.id }
    let formatter = DateFormatter()
    formatter.calendar = calendar
    formatter.timeZone = calendar.timeZone
    formatter.locale = calendar.locale ?? .current
    formatter.setLocalizedDateFormatFromTemplate("MMMM yyyy")
    return formatter.string(from: date)
}

func dapiUSDText(_ amount: Decimal?) -> String {
    amount.map { money(NSDecimalNumber(decimal: $0)) } ?? "—"
}

func dapiSpendRangeText(_ entry: DapiSpendCountry) -> String {
    guard let lowest = entry.lowest, let highest = entry.highest else { return "—" }
    return lowest == highest ? dapiUSDText(lowest) : "\(dapiUSDText(lowest))–\(dapiUSDText(highest))"
}

func dapiSpendOtherCurrencyText(_ entry: DapiSpendOtherCurrency) -> String {
    guard let minor = entry.totalPaidMinor else { return "\(entry.currency): too large to add up" }
    return dapiMoneyText(DapiMoney(amountMinor: minor, currency: entry.currency.lowercased()))
}

/// The report as plain text for Copy as Text.
func dapiSpendReportText(_ report: DapiSpendReport, notes: [String], calendar: Calendar = .current) -> String {
    var lines = ["3DAPI spending report", ""]
    lines += notes
    if !notes.isEmpty { lines.append("") }
    for month in report.months {
        var line = "\(dapiSpendMonthTitle(month, calendar: calendar)): \(dapiUSDText(month.totalPaid)) for \(month.orders == 1 ? "1 order" : "\(month.orders) orders"), \(month.units == 1 ? "1 unit" : "\(month.units) units")"
        if month.ordersWithoutUnits > 0 { line += " (units unknown for \(month.ordersWithoutUnits))" }
        line += " · items \(dapiUSDText(month.items)), shipping \(dapiUSDText(month.shipping)), VAT \(dapiUSDText(month.vat))"
        if month.sampleCredit > 0 { line += ", sample credit −\(dapiUSDText(month.sampleCredit))" }
        if month.refunds > 0 { line += ", refunds −\(dapiUSDText(month.refunds))" }
        lines.append(line)
    }
    lines.append("Total: \(dapiUSDText(report.totalPaid)) for \(report.countedOrders == 1 ? "1 order" : "\(report.countedOrders) orders")")
    if !report.countries.isEmpty {
        lines.append("")
        lines.append("Shipping by destination country:")
        for country in report.countries {
            lines.append("\(spendReportCountryTitle(country.countryCode)): \(country.orders == 1 ? "1 order" : "\(country.orders) orders"), average \(dapiUSDText(country.average)), \(dapiSpendRangeText(country))")
        }
    }
    if !report.otherCurrencies.isEmpty {
        lines.append("")
        lines.append("Other currencies (not added to the USD figures):")
        for entry in report.otherCurrencies {
            lines.append("\(entry.currency): \(dapiSpendOtherCurrencyText(entry)) for \(entry.orders == 1 ? "1 order" : "\(entry.orders) orders")")
        }
    }
    if let exclusions = dapiSpendExclusionLine(report) {
        lines.append("")
        lines.append(exclusions)
    }
    return lines.joined(separator: "\n") + "\n"
}

/// The report as CSV through `csvField`: months, then countries, then other currencies (each with its code).
func dapiSpendReportCSV(_ report: DapiSpendReport) -> String {
    var rows: [[String]] = [["Month", "Orders", "Units", "Orders without units", "Items (USD)", "Shipping (USD)", "VAT (USD)",
                             "Sample credit (USD)", "Refunds (USD)", "Total paid (USD)"]]
    for month in report.months {
        rows.append([month.id, String(month.orders), String(month.units), String(month.ordersWithoutUnits),
                     spendReportCSVAmount(month.items), spendReportCSVAmount(month.shipping), spendReportCSVAmount(month.vat),
                     spendReportCSVAmount(month.sampleCredit), spendReportCSVAmount(month.refunds), spendReportCSVAmount(month.totalPaid)])
    }
    if !report.countries.isEmpty {
        rows.append([])
        rows.append(["Destination country", "Country code", "Orders", "Shipping (USD)", "Average (USD)", "Lowest (USD)", "Highest (USD)"])
        for country in report.countries {
            rows.append([spendReportCountryTitle(country.countryCode, locale: Locale(identifier: "en_US")), country.countryCode,
                         String(country.orders), spendReportCSVAmount(country.totalShipping),
                         country.average.map(spendReportCSVAmount) ?? "", country.lowest.map(spendReportCSVAmount) ?? "",
                         country.highest.map(spendReportCSVAmount) ?? ""])
        }
    }
    if !report.otherCurrencies.isEmpty {
        rows.append([])
        rows.append(["Other currency", "Orders", "Total paid"])
        for entry in report.otherCurrencies {
            rows.append([entry.currency, String(entry.orders),
                         entry.totalPaidMinor.map { dapiCSVAmount(DapiMoney(amountMinor: $0, currency: entry.currency.lowercased())) } ?? ""])
        }
    }
    return rows.map { $0.map(csvField).joined(separator: ",") }.joined(separator: "\r\n") + "\r\n"
}

// MARK: - Load the whole period

/// At most this many pages of 100 for one report.
let dapiSpendPeriodMaxPages = 50
let dapiSpendPeriodPageSize = 100
/// Time between page reads.
let dapiSpendPeriodPageSpacing: TimeInterval = 0.6

/// The list query for one page: a day's margin either side (3DAPI's `created_after`/`created_before` bounds aren't
/// documented as inclusive or exclusive), trimmed afterwards by `dapiSpendPeriodOrders`. Lines are included for units.
func dapiSpendPeriodQuery(_ interval: SpendReportInterval, cursor: String?, calendar: Calendar = .current) -> DapiOrderListQuery {
    DapiOrderListQuery(createdAfter: calendar.date(byAdding: .day, value: -1, to: interval.start) ?? interval.start,
                       createdBefore: calendar.date(byAdding: .day, value: 1, to: interval.end) ?? interval.end,
                       cursor: cursor, limit: dapiSpendPeriodPageSize, expandItems: true)
}

/// Adds a page: orders created outside the period are dropped, and an order already loaded (by ID) isn't added again.
/// Orders without a date are kept (the report counts them as undated).
func dapiSpendPeriodOrders(_ existing: [DapiOrder], adding page: [DapiOrder], interval: SpendReportInterval) -> [DapiOrder] {
    var seen = Set(existing.map(\.id))
    var result = existing
    for order in page {
        if let created = order.createdAt, !interval.contains(created) { continue }
        guard seen.insert(order.id).inserted else { continue }
        result.append(order)
    }
    return result
}

enum DapiSpendPageStep: Equatable {
    case next(String)
    case complete
    case capReached
    /// 3DAPI said there was more but gave no cursor: stop rather than call it complete.
    case noCursor
}

/// The next step after a page, decided from 3DAPI's `has_more` and `next_cursor` only (never from an empty page).
func dapiSpendPageStep(pagesLoaded: Int, page: DapiOrderPage, maxPages: Int = dapiSpendPeriodMaxPages) -> DapiSpendPageStep {
    guard page.hasMore else { return .complete }
    guard let cursor = page.nextCursor, !cursor.isEmpty else { return .noCursor }
    return pagesLoaded >= maxPages ? .capReached : .next(cursor)
}

/// Why loading stopped, as the sheet shows it. Nothing is retried; Continue Loading carries on from the next page.
func dapiSpendLoadStopMessage(_ error: Error, now: Date = Date()) -> String {
    if dapiIsCancellation(error) { return "Stopped. Orders already loaded are kept." }
    if case DapiError.rateLimited(_, let retryAt) = error {
        let wait = retryAt.map { max(0, $0.timeIntervalSince(now)) } ?? 60
        let minutes = Int((min(wait, 3600) / 60).rounded(.up))
        let when = minutes <= 1 ? "about a minute" : "about \(minutes) minutes"
        return "Stopped: 3DAPI is limiting requests. Wait \(when), then choose Continue Loading. Orders already loaded are kept."
    }
    let text = (error as? DapiError)?.userMessage ?? dapiRedacted(error.localizedDescription)
    return "Stopped: \(text) Orders already loaded are kept; choose Continue Loading to try the next page."
}

/// Notes for a report built from a loaded period.
func dapiSpendPeriodNotes(complete: Bool, capReached: Bool, loadedCount: Int, lastCreated: Date?, calendar: Calendar = .current) -> [String] {
    var notes: [String] = []
    if !complete {
        let reach = lastCreated.map { date -> String in
            let formatter = DateFormatter()
            formatter.calendar = calendar
            formatter.timeZone = calendar.timeZone
            formatter.locale = calendar.locale ?? .current
            formatter.dateStyle = .medium
            formatter.timeStyle = .none
            return " It reaches back to orders created on \(formatter.string(from: date))."
        } ?? ""
        if capReached {
            notes.append("Not the whole period: Plinth loads at most \(dapiSpendPeriodMaxPages) pages (\((dapiSpendPeriodMaxPages * dapiSpendPeriodPageSize).formatted()) orders) for one report.\(reach) Choose a shorter period to see the rest.")
        } else {
            notes.append("Not the whole period yet: \(spendReportLoadedCountText(loadedCount)) loaded.\(reach) Choose Continue Loading for the rest.")
        }
    }
    notes.append("These orders are only used here; the Orders list isn’t changed.")
    return notes
}

/// Load the Whole Period for the 3DAPI spending report: read-only list pages (newest first, by cursor), ≤ 50 pages,
/// 0.6 s apart. It stops (keeping what it loaded) on Stop, on closing the sheet, after a 429 or any failure, and is
/// never retried automatically: Continue Loading reads the next page. The orders live in the sheet's memory only. While
/// it runs it counts as a 3DAPI request, so the key can't change under it.
@MainActor final class DapiSpendPeriodLoader: ObservableObject {
    struct Load: Equatable {
        let period: SpendReportPeriod
        let interval: SpendReportInterval
        var orders: [DapiOrder] = []
        var pagesLoaded = 0
        var cursor: String?
        var complete = false
        var capReached = false
        var lastCreated: Date?
    }

    @Published private(set) var load: Load?
    @Published private(set) var running = false
    @Published private(set) var message: String?

    private var task: Task<Void, Never>?
    private var generation = 0
    private let makeClient: @MainActor () throws -> any DapiOrdering
    private let sleep: @Sendable (TimeInterval) async throws -> Void
    private let beginRequest: @MainActor () -> Void
    private let endRequest: @MainActor () -> Void
    private let calendar: Calendar
    private let now: () -> Date

    init(makeClient: @escaping @MainActor () throws -> any DapiOrdering = { try DapiConnection.shared.currentOrderingClient() },
         sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000)) },
         beginRequest: @escaping @MainActor () -> Void = { DapiConnection.shared.beginRequest() },
         endRequest: @escaping @MainActor () -> Void = { DapiConnection.shared.endRequest() },
         calendar: Calendar = .current, now: @escaping () -> Date = Date.init) {
        self.makeClient = makeClient
        self.sleep = sleep
        self.beginRequest = beginRequest
        self.endRequest = endRequest
        self.calendar = calendar
        self.now = now
    }

    var canContinue: Bool {
        guard let load, !running else { return false }
        return !load.complete && !load.capReached
    }

    /// Load the Whole Period: replaces what was loaded and reads from the newest page.
    func start(_ period: SpendReportPeriod) {
        guard !running else { return }
        load = Load(period: period, interval: spendReportPeriodInterval(period, now: now(), calendar: calendar))
        run()
    }

    func continueLoading() {
        guard canContinue else { return }
        run()
    }

    /// Back to the loaded orders: forgets the period.
    func reset() {
        guard !running else { return }
        load = nil
        message = nil
    }

    /// Stop and sheet close: cancels the page being read; nothing that arrives afterwards is used.
    func stop() {
        guard running else { return }
        generation += 1
        task?.cancel()
        task = nil
        running = false
        endRequest()
        message = "Stopped. Orders already loaded are kept."
    }

    /// The running load, for tests.
    func waitForCompletion() async { await task?.value }

    private func run() {
        let client: any DapiOrdering
        do {
            client = try makeClient()
        } catch {
            // Nothing started, so not "Stopped": just why (usually no saved key).
            message = (error as? DapiError)?.userMessage ?? dapiRedacted(error.localizedDescription)
            return
        }
        generation += 1
        let runGeneration = generation
        running = true
        message = nil
        beginRequest()
        task = Task { [weak self] in
            await self?.fetchPages(client: client, generation: runGeneration)
        }
    }

    private func fetchPages(client: any DapiOrdering, generation runGeneration: Int) async {
        var first = true
        var stopMessage: String?
        while runGeneration == generation, var current = load {
            if current.complete || current.capReached { break }
            do {
                if !first { try await sleep(dapiSpendPeriodPageSpacing) }
                first = false
                try Task.checkCancellation()
                guard runGeneration == generation else { return }
                let page = try await client.orders(dapiSpendPeriodQuery(current.interval, cursor: current.cursor, calendar: calendar))
                guard runGeneration == generation else { return }
                current.orders = dapiSpendPeriodOrders(current.orders, adding: page.orders, interval: current.interval)
                current.lastCreated = current.orders.compactMap(\.createdAt).min()
                current.pagesLoaded += 1
                switch dapiSpendPageStep(pagesLoaded: current.pagesLoaded, page: page) {
                case .next(let cursor): current.cursor = cursor
                case .complete: current.complete = true
                case .capReached: current.capReached = true
                case .noCursor:
                    stopMessage = "Stopped: 3DAPI said there were more orders but didn’t say where to read them from. Orders already loaded are kept."
                }
                load = current
                if stopMessage != nil { break }
            } catch {
                guard runGeneration == generation else { return }
                stopMessage = dapiSpendLoadStopMessage(error, now: now())
                break
            }
        }
        guard runGeneration == generation else { return }
        running = false
        task = nil
        endRequest()
        message = stopMessage
    }
}

// MARK: - Tracking for your shop

/// One loaded order with tracking.
struct DapiTrackingEntry: Identifiable, Equatable {
    let id: String
    let number: String
    let reference: String?
    let carrier: String?
    let trackingNumber: String
    let status: DapiOrderStatus
    let created: Date?
}

struct DapiTrackingGroups: Equatable {
    /// Orders with a reference, newest first.
    var withReference: [DapiTrackingEntry] = []
    /// Orders with tracking but no reference, newest first.
    var withoutReference: [DapiTrackingEntry] = []
    /// Orders marked done this session (left out unless shown).
    var doneCount = 0
    var listed: [DapiTrackingEntry] { withReference + withoutReference }
}

func dapiTrackingEntry(_ order: DapiOrder) -> DapiTrackingEntry? {
    guard let tracking = dapiNonEmpty(order.shipping.trackingNumber) else { return nil }
    // The seller's own reference only: Plinth's bare "plinth_…" code counts as none (`dapiOrderSellerReference`).
    return DapiTrackingEntry(id: order.id, number: order.number, reference: dapiOrderSellerReference(order.reference),
                             carrier: dapiNonEmpty(order.shipping.carrier), trackingNumber: tracking,
                             status: order.status, created: order.createdAt)
}

/// Every loaded order with tracking, grouped by whether it carries a reference, newest first (undated last, ties in
/// the loaded order). Orders in `done` are counted, and listed only when `showDone`.
func dapiTrackingGroups(_ orders: [DapiOrder], done: Set<String>, showDone: Bool = false) -> DapiTrackingGroups {
    let entries = orders.enumerated().compactMap { offset, order in dapiTrackingEntry(order).map { (offset, $0) } }
        .sorted { lhs, rhs in
            let left = lhs.1.created ?? .distantPast, right = rhs.1.created ?? .distantPast
            return left != right ? left > right : lhs.0 < rhs.0
        }
        .map(\.1)
    var groups = DapiTrackingGroups()
    var listed = Set<String>()
    for entry in entries where listed.insert(entry.id).inserted {
        let isDone = done.contains(entry.id)
        if isDone { groups.doneCount += 1 }
        guard !isDone || showDone else { continue }
        if entry.reference != nil { groups.withReference.append(entry) } else { groups.withoutReference.append(entry) }
    }
    return groups
}

func dapiTrackingTitle(_ entry: DapiTrackingEntry) -> String {
    entry.reference ?? "3DAPI order \(entry.number)"
}

/// What Copy puts on the clipboard: "ETSY-3141592653 — DHL 1234567890" (the reference, else 3DAPI's number). Never a
/// customer's name.
func dapiTrackingCopyText(_ entry: DapiTrackingEntry) -> String {
    let tracking = entry.carrier.map { "\($0) \(entry.trackingNumber)" } ?? entry.trackingNumber
    return "\(entry.reference ?? entry.number) — \(tracking)"
}

/// Copy All: one line per entry.
func dapiTrackingCopyAllText(_ entries: [DapiTrackingEntry]) -> String {
    entries.map(dapiTrackingCopyText).joined(separator: "\n")
}

/// Why tracking isn't sent to Shopify for 3DAPI orders (one line in the sheet).
let dapiTrackingNoShopifyNote = "Plinth can’t send 3DAPI tracking to Shopify, because 3DAPI orders don’t record which Shopify items they fulfil. Copy it into your shop instead."

/// Session-only marks for the 3DAPI tools: Tracking for Your Shop's done ticks, by order ID. Memory only.
@MainActor final class DapiOrderToolsState: ObservableObject {
    static let shared = DapiOrderToolsState()
    @Published var trackingDoneIDs: Set<String> = []
}
