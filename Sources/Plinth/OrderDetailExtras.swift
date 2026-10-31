import Foundation
import SwiftUI
import AppKit

// MARK: - Order detail extras
//
// Display-only additions to the order detail: per-item production progress, a label-address check, a support message
// to copy, and the "Review Next Draft" step between charge reviews. Nothing here sends a request, pays, saves order
// data or touches the unknown-outcome lock; paying still happens only through `OrderActionConfirmSheet`.

// MARK: Production progress (unverified fields)

/// Order statuses whose production progress isn't worth showing: drafts haven't started (Slant reported their items as
/// PROCESSING with no assignments on 23 Oct 2026, and as DRAFT on 29 Oct 2026), and cancelled, shipped or delivered
/// orders are past it. Callers pass `orderDisplayStatus`, so an order whose shipping record says it shipped is too.
let orderProgressHiddenStatuses: Set<String> = ["DRAFT", "CANCELED", "CANCELLED", "SHIPPED", "DELIVERED", "PAYMENT_ERROR"]

/// One item's production progress from Slant's `estimatedPrintCompletion` and `assignments` fields. Neither is in the
/// bundled OpenAPI, and Slant's docs stopped mentioning `assignments` with the status change of 26 Oct 2026 (item
/// status now always equals the order's), so both are read defensively and nothing is shown when they're absent.
struct OrderItemProgress: Equatable {
    /// "Printing", or counts such as "2 printing · 1 on the shelf" when the item's assignments differ.
    var stage: String?
    var estimatedCompletion: Date?
    /// True when the estimate came as a date without a time.
    var estimateIsDateOnly = false
}

/// Assignment status → display words, in pipeline order. Unknown statuses are shown as Slant sent them.
private let orderAssignmentStageOrder = ["QUEUED", "PRINTING", "PRINTED", "POST_PROCESSING", "ON_SHELF"]
func orderAssignmentStageTitle(_ raw: String) -> String {
    switch raw.uppercased() {
    case "QUEUED": return "In queue"
    case "PRINTING": return "Printing"
    case "PRINTED": return "Printed"
    case "POST_PROCESSING": return "Finishing"
    case "ON_SHELF", "ITEMS_ON_SHELF": return "On the shelf"
    default:
        let words = raw.replacingOccurrences(of: "_", with: " ").lowercased()
        return words.prefix(1).uppercased() + words.dropFirst()
    }
}

/// The item's assignments: from `printItem` (where Slant returns them) or, failing that, the flat item.
/// Non-object elements are skipped.
func orderItemAssignments(_ item: [String: Any]) -> [[String: Any]] {
    let nested = ((item["printItem"] as? [String: Any])?["assignments"] as? [Any] ?? []).compactMap { $0 as? [String: Any] }
    if !nested.isEmpty { return nested }
    return (item["assignments"] as? [Any] ?? []).compactMap { $0 as? [String: Any] }
}

/// A short summary of the assignments' `status` values, or nil when none has one. One status reads "Printing";
/// several read "2 printing · 1 on the shelf", in pipeline order. `krakenStatus` and printer details are not used:
/// their meaning isn't documented well enough to show sellers.
func orderAssignmentStageSummary(_ assignments: [[String: Any]]) -> String? {
    var counts: [String: Int] = [:]
    var firstSeen: [String] = []
    for assignment in assignments {
        guard let raw = (assignment["status"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { continue }
        let key = raw.uppercased() == "ITEMS_ON_SHELF" ? "ON_SHELF" : raw.uppercased()
        if counts[key] == nil { firstSeen.append(key) }
        counts[key, default: 0] += 1
    }
    guard !counts.isEmpty else { return nil }
    if counts.count == 1, let only = firstSeen.first { return orderAssignmentStageTitle(only) }
    let known = orderAssignmentStageOrder.filter { counts[$0] != nil }
    let unknown = firstSeen.filter { !orderAssignmentStageOrder.contains($0) }
    return (known + unknown).map { key in
        "\(counts[key] ?? 0) \(orderAssignmentStageTitle(key).lowercased())"
    }.joined(separator: " · ")
}

/// Reads an estimated completion time: an ISO 8601 date-time (with or without fractional seconds), a plain
/// `yyyy-MM-dd` date, or an epoch number (milliseconds when large, else seconds). Anything else, including
/// booleans and implausible years, is ignored.
func orderProgressDate(_ value: Any?) -> (date: Date, dateOnly: Bool)? {
    guard let value, !(value is NSNull) else { return nil }
    let plausible: (Date) -> Bool = { date in
        let year = Calendar(identifier: .gregorian).component(.year, from: date)
        return (2000...2100).contains(year)
    }
    if let number = value as? NSNumber {
        guard CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let raw = number.doubleValue
        guard raw.isFinite, raw > 0 else { return nil }
        let date = Date(timeIntervalSince1970: raw >= 100_000_000_000 ? raw / 1000 : raw)
        return plausible(date) ? (date, false) : nil
    }
    guard let text = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = fractional.date(from: text) ?? ISO8601DateFormatter().date(from: text), plausible(date) {
        return (date, false)
    }
    if text.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil {
        let dayOnly = ISO8601DateFormatter()
        dayOnly.formatOptions = [.withFullDate]
        if let date = dayOnly.date(from: text), plausible(date) { return (date, true) }
    }
    return nil
}

/// The item's production progress, or nil when there's nothing to show: a draft or finished order, or neither
/// assignments with a status nor a readable estimate. The estimate is read from the item, then its `printItem`.
func orderItemProgress(_ item: [String: Any], orderStatus: String) -> OrderItemProgress? {
    let status = orderStatus.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    guard !orderProgressHiddenStatuses.contains(status) else { return nil }
    let stage = orderAssignmentStageSummary(orderItemAssignments(item))
    let estimate = orderProgressDate(item["estimatedPrintCompletion"])
        ?? orderProgressDate((item["printItem"] as? [String: Any])?["estimatedPrintCompletion"])
    guard stage != nil || estimate != nil else { return nil }
    return OrderItemProgress(stage: stage, estimatedCompletion: estimate?.date, estimateIsDateOnly: estimate?.dateOnly ?? false)
}

/// "24 Oct, 15:10" in the user's locale; the year is added when it isn't this year. A date-only estimate is formatted
/// in UTC so it shows the day Slant sent.
func orderProgressDateText(_ date: Date, dateOnly: Bool = false, now: Date = Date(),
                           locale: Locale = .current, timeZone: TimeZone = .current) -> String {
    let zone = dateOnly ? TimeZone(identifier: "UTC")! : timeZone
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = zone
    let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
    let formatter = DateFormatter()
    formatter.locale = locale
    formatter.timeZone = zone
    formatter.setLocalizedDateFormatFromTemplate((sameYear ? "dMMM" : "dMMMy") + (dateOnly ? "" : "jmm"))
    return formatter.string(from: date)
}

/// One caption line: "Printing · due to finish 24 Oct, 15:10", "On the shelf" or "Due to finish 24 Oct".
func orderItemProgressLine(_ progress: OrderItemProgress, now: Date = Date(),
                           locale: Locale = .current, timeZone: TimeZone = .current) -> String? {
    let estimate = progress.estimatedCompletion.map {
        orderProgressDateText($0, dateOnly: progress.estimateIsDateOnly, now: now, locale: locale, timeZone: timeZone)
    }
    switch (progress.stage, estimate) {
    case (let stage?, let estimate?): return "\(stage) · due to finish \(estimate)"
    case (let stage?, nil): return stage
    case (nil, let estimate?): return "Due to finish \(estimate)"
    case (nil, nil): return nil
    }
}

func orderItemProgressLine(_ item: [String: Any], orderStatus: String) -> String? {
    orderItemProgress(item, orderStatus: orderStatus).flatMap { orderItemProgressLine($0) }
}

// MARK: Label address check

/// The parts of an address compared against the label: street, city, postcode and country.
struct OrderComparableAddress: Equatable {
    var line1 = ""
    var line2 = ""
    var city = ""
    var zip = ""
    var country = ""
}

/// Reads a flat address object, accepting Slant's `line1`/`zip` and the label providers' usual `street1`/`postalCode`
/// spellings, in case a label address arrives in a provider's shape.
func orderComparableAddress(_ value: Any?) -> OrderComparableAddress? {
    guard let object = value as? [String: Any] else { return nil }
    func first(_ keys: [String]) -> String {
        for key in keys {
            if let text = (object[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty { return text }
        }
        return ""
    }
    let address = OrderComparableAddress(
        line1: first(["line1", "street1", "address1", "addressLine1", "street"]),
        line2: first(["line2", "street2", "address2", "addressLine2"]),
        city: first(["city"]),
        zip: first(["zip", "postalCode", "postal_code", "zipCode", "postcode"]),
        country: first(["country", "countryCode", "country_code"])
    )
    return address == OrderComparableAddress() ? nil : address
}

/// Common street-word abbreviations, so "123 Main Street" and a label's "123 MAIN ST" compare equal.
private let orderStreetAbbreviations: [String: String] = [
    "street": "st", "avenue": "ave", "road": "rd", "drive": "dr", "boulevard": "blvd", "lane": "ln", "court": "ct",
    "place": "pl", "terrace": "ter", "highway": "hwy", "parkway": "pkwy", "circle": "cir", "square": "sq",
    "apartment": "apt", "suite": "ste", "north": "n", "south": "s", "east": "e", "west": "w",
    "northeast": "ne", "northwest": "nw", "southeast": "se", "southwest": "sw"
]

/// Lower-cased words without punctuation, single-spaced, with street words abbreviated.
func orderNormalisedAddressText(_ text: String, abbreviate: Bool = false) -> String {
    let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    let words = folded.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
    return words.map { abbreviate ? (orderStreetAbbreviations[$0] ?? $0) : $0 }.joined(separator: " ")
}

/// A country as an ISO code when it is one or names one, otherwise its normalised text.
func orderNormalisedCountry(_ text: String) -> String {
    let picked = orderCountrySelection(fromAddressCountry: text)
    let code = picked.selection == orderCountryOtherTag ? picked.customCode : picked.selection
    return code.isEmpty ? orderNormalisedAddressText(text) : code.uppercased()
}

/// Postcodes compare by letters and digits only; a US ZIP+4 matches its five-digit ZIP.
func orderPostcodesMatch(_ lhs: String, _ rhs: String) -> Bool {
    let clean: (String) -> String = { $0.uppercased().filter { $0.isLetter || $0.isNumber } }
    let a = clean(lhs), b = clean(rhs)
    if a == b { return true }
    let digitsOnly = a.allSatisfy(\.isNumber) && b.allSatisfy(\.isNumber)
    if digitsOnly, (a.count == 5 && b.count == 9 && b.hasPrefix(a)) || (b.count == 5 && a.count == 9 && a.hasPrefix(b)) { return true }
    return false
}

/// Which compared parts differ ("street", "city", "postcode", "country"). A part is compared only when both
/// addresses have it, so a sparse label address never counts as a difference. The street is line 1 and line 2
/// together, so a unit number moved from one line to the other doesn't count either.
func orderLabelAddressDifferences(label: OrderComparableAddress, shipping: OrderComparableAddress) -> [String] {
    var differences: [String] = []
    let street: (OrderComparableAddress) -> String = { orderNormalisedAddressText($0.line1 + " " + $0.line2, abbreviate: true) }
    if !label.line1.isEmpty, !shipping.line1.isEmpty, street(label) != street(shipping) {
        differences.append("street")
    }
    if !label.city.isEmpty, !shipping.city.isEmpty, orderNormalisedAddressText(label.city) != orderNormalisedAddressText(shipping.city) {
        differences.append("city")
    }
    if !label.zip.isEmpty, !shipping.zip.isEmpty, !orderPostcodesMatch(label.zip, shipping.zip) {
        differences.append("postcode")
    }
    if !label.country.isEmpty, !shipping.country.isEmpty, orderNormalisedCountry(label.country) != orderNormalisedCountry(shipping.country) {
        differences.append("country")
    }
    return differences
}

/// The one-line advisory when Slant's `fulfillment.address` (the address its label was made for) differs from the
/// order's shipping address, with the parts that differ for a tooltip; nil when either is absent or they match.
/// Live Slant nests it like the order's own details, `{email, address: {name, line1, …}}` (docs and live, 29 Oct
/// 2026); a flat address is read too. Only street, city, state, postcode and country are shown: never the label's
/// email or name. Display only: neither address is stored.
func orderLabelAddressAdvisory(_ order: [String: Any]) -> (line: String, differences: [String])? {
    guard let outer = (order["fulfillment"] as? [String: Any])?["address"] as? [String: Any] else { return nil }
    let rawLabel = (outer["address"] as? [String: Any]) ?? outer
    guard let label = orderComparableAddress(rawLabel),
          let shipping = orderComparableAddress(((order["customer"] as? [String: Any])?["details"] as? [String: Any])?["address"]) else { return nil }
    let differences = orderLabelAddressDifferences(label: label, shipping: shipping)
    guard !differences.isEmpty else { return nil }
    let keys = ["line1", "street1", "address1", "line2", "street2", "address2", "city", "state", "zip", "postalCode", "country"]
    var seen = Set<String>()
    let parts = keys.compactMap { key -> String? in
        guard let text = (rawLabel[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty,
              seen.insert(text.lowercased()).inserted else { return nil }
        return text
    }
    return ("The shipping label was made for: " + parts.joined(separator: ", ") + ". Check with Slant if this is wrong.", differences)
}

// MARK: Report a problem

enum OrderProblemKind: String, CaseIterable, Identifiable {
    case damaged, wrongItem, missingItem, printDefect, late, other
    var id: String { rawValue }
    var title: String {
        switch self {
        case .damaged: return "Damaged item"
        case .wrongItem: return "Wrong item"
        case .missingItem: return "Missing item"
        case .printDefect: return "Print defect"
        case .late: return "Late delivery"
        case .other: return "Other"
        }
    }
}

/// Slant's docs name support@slant3d.com (its Technical Support section). The caption names it as text only: the
/// sheet offers Copy and never opens a mail link or sends anything.
let orderProblemSupportAddress = "support@slant3d.com"
let orderProblemReportCaption = "Plinth puts together a message with this order’s details for you to send to Slant support (\(orderProblemSupportAddress)). It doesn’t send anything itself: copy the message and paste it into your email or support request. Names and addresses aren’t included."

/// Where a late order is held up, from Slant's own data (read-only advice; the Late delivery problem only).
enum OrderLateStage: Equatable {
    /// Being made, with no shipping label yet (no shipping record date and no tracking number): the delay is at Slant.
    case atSlant
    /// Slant's shipping record says it shipped, or a shipping label exists (a shipping record date or a tracking
    /// number): most likely with the carrier.
    case withCarrier
}

/// Where a late order is: with the carrier once the shipping record says SHIPPED or DELIVERED (`orderDisplayStatus`,
/// so a lagging order status still counts as shipped), or once a shipping label exists (Slant's shipping record date,
/// `fulfillment.createdAt`, or any tracking number); at Slant while the status is a production status with neither.
/// Nil for drafts, cancelled orders and statuses Plinth doesn't know. Slant sends `fulfillment` as null until a label
/// is made (live, Oct 2026). Display and advice only.
func orderLateStage(_ order: [String: Any]) -> OrderLateStage? {
    let shown = orderDisplayStatus(order).trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    let raw = ((order["status"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    if orderFulfillmentShippedStatuses.contains(shown) { return .withCarrier }
    guard orderAttentionProductionStatuses.contains(raw) else { return nil }
    let labelMade = orderShippingRecordCreatedDate(order) != nil || !orderTrackingNumbers(order).isEmpty
    return labelMade ? .withCarrier : .atSlant
}

/// What Plinth says under the problem picker; nil when there's nothing particular. Only Late delivery has advice,
/// and it depends on whether the order has left Slant (`orderLateStage`). At Slant, the seller's own usual time to a
/// shipping label (`typical`, `orderShipTimeSummary` over the default platform's loaded orders) puts the wait in
/// context: "Paid 1 business day ago; your recent orders usually got a shipping label after 3. It may not be late
/// yet." Never a claim window or a promise.
func orderProblemGuidance(_ kind: OrderProblemKind, order: [String: Any], typical: OrderShipTimeSummary? = nil,
                          now: Date = Date(), timeZone: TimeZone = .current) -> String? {
    guard kind == .late, let stage = orderLateStage(order) else { return nil }
    switch stage {
    case .atSlant:
        let send = "Send this message to Slant support; it says when the order was paid."
        guard let typical, let paid = orderPaidDate(order) else {
            return "Slant hasn’t made a shipping label for this order yet, so the delay is at Slant, not with the carrier. " + send
        }
        let calendar = orderBusinessDayCalendar(timeZone: timeZone)
        let days = paid > now ? 0 : orderBusinessDays(from: paid, to: now, calendar: calendar)
        let when = typical.median == 0 ? "the same business day" : "after \(orderShipTimeNumberText(typical.median))"
        let usual = "Paid \(orderPaidAgoText(paid, now: now, timeZone: timeZone)); your recent orders usually got a shipping label \(when)."
        if Double(days) < typical.median {
            return "Slant hasn’t made a shipping label for this order yet. \(usual) It may not be late yet. If you still want to ask, send this message to Slant support; it says when the order was paid."
        }
        return "Slant hasn’t made a shipping label for this order yet, so the delay is at Slant, not with the carrier. \(usual) " + send
    case .withCarrier:
        let shown = orderDisplayStatus(order).trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let lead = orderFulfillmentShippedStatuses.contains(shown)
            ? "Slant’s shipping record says this order has shipped, so this is most likely a carrier delay."
            : "Slant has made a shipping label for this order, so it may be with the carrier."
        guard !orderTrackingNumbers(order).isEmpty else {
            return lead + " Slant hasn’t listed a tracking number, so send this message to Slant support and ask for it."
        }
        return lead + " Check the tracking first. If the carrier hasn’t scanned the parcel, or the tracking has stopped moving, send this message to Slant support; it includes the tracking number."
    }
}

/// The carrier whose tracking page Report a Problem's Track Parcel opens for a late order with the carrier: one every
/// tracking number names unambiguously (`carrierDetected`, agreeing with any carrier Slant named) and that has a page;
/// nil otherwise. Opened only on the seller's click.
func orderProblemTrackingCarrier(_ kind: OrderProblemKind?, order: [String: Any]) -> DetectedCarrier? {
    guard kind == .late, orderLateStage(order) == .withCarrier else { return nil }
    let numbers = orderTrackingNumbers(order)
    guard numbers.count == 1, let carrier = carrierDetected(forNumbers: numbers, namedCarrier: fulfillmentProvider(order["fulfillment"])),
          carrier.trackingURL != nil else { return nil }
    return carrier
}

/// "31 October 2026" in the Mac's time zone, in English (the message is written in English).
func orderProblemDateText(_ date: Date, timeZone: TimeZone = .current) -> String {
    let formatter = DateFormatter()
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.locale = Locale(identifier: "en_GB")
    formatter.timeZone = timeZone
    formatter.dateFormat = "d MMMM yyyy"
    return formatter.string(from: date)
}

/// "today", "yesterday" or "5 days ago", by calendar days in `calendar`'s time zone; nil for a date after `now`.
/// Shared by Slant's and 3DAPI's problem messages.
func problemReportDaysAgoText(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String? {
    let start = calendar.startOfDay(for: date)
    let end = calendar.startOfDay(for: now)
    guard let days = calendar.dateComponents([.day], from: start, to: end).day, days >= 0 else { return nil }
    switch days {
    case 0: return "today"
    case 1: return "yesterday"
    default: return "\(days) days ago"
    }
}

/// "29 October 2026 (3 days ago)", or just the date when the days can't be counted.
func problemReportDateWithAge(_ date: Date, now: Date, calendar: Calendar) -> String {
    let text = orderProblemDateText(date, timeZone: calendar.timeZone)
    return problemReportDaysAgoText(date, now: now, calendar: calendar).map { "\(text) (\($0))" } ?? text
}

/// The extra message lines for Late delivery: when it was paid (Slant's `processedAt`) and that there's no shipping
/// label yet, or when the shipping label was created (`fulfillment.createdAt`). Only dates Slant sent; a missing or
/// unreadable one is left out, never guessed.
func orderLateProblemLines(_ order: [String: Any], now: Date = Date(), calendar: Calendar = .current) -> [String] {
    guard let stage = orderLateStage(order) else { return [] }
    var lines: [String] = []
    switch stage {
    case .atSlant:
        if let raw = order["processedAt"] as? String, let paid = orderTimestamp(raw) {
            lines.append("Paid: \(problemReportDateWithAge(paid, now: now, calendar: calendar))")
        }
        lines.append("Shipping label: not made yet")
    case .withCarrier:
        if let raw = (order["fulfillment"] as? [String: Any])?["createdAt"] as? String, let made = orderTimestamp(raw) {
            lines.append("Shipping label created: \(problemReportDateWithAge(made, now: now, calendar: calendar))")
        }
    }
    return lines
}

/// The support message: order number, status, created date, tracking numbers, items with quantities and materials,
/// the problem and the seller's description. No recipient name, email or address. A late order also gets
/// `orderLateProblemLines`.
func orderProblemMessage(order: [String: Any], problem: OrderProblemKind, details: String,
                         modelNames: [String: String] = [:], filaments: [Record] = [],
                         now: Date = Date(), calendar: Calendar = .current) -> String {
    let number = orderNumber(order)
    let reference = number.isEmpty ? "my order" : "order \(number)"
    var lines = ["Hello Slant team,", "", "I’d like to report a problem with \(reference): \(problem.title.lowercased()).", ""]
    if !number.isEmpty { lines.append("Order number: \(number)") }
    let status = (order["status"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    // Slant's order status and, when it says something else, its shipping record's (which can be ahead of it):
    // "Status: Printing · Shipping record: Shipped".
    var statusParts: [String] = []
    if !status.isEmpty { statusParts.append("Status: \(orderStatusTitle(status))") }
    if let shipping = orderFulfillmentStatus(order), shipping != status.uppercased() {
        statusParts.append("Shipping record: \(orderStatusTitle(orderStatusQuoted(shipping)))")
    }
    if !statusParts.isEmpty { lines.append(statusParts.joined(separator: " · ")) }
    if let created = orderCreatedDisplay(order) { lines.append("Created: \(created)") }
    for (label, value) in trackingFacts(order["fulfillment"]) where label == "Tracking number" {
        lines.append("Tracking number: \(value)")
    }
    if problem == .late { lines += orderLateProblemLines(order, now: now, calendar: calendar) }
    lines.append("Problem: \(problem.title)")
    let items = order["items"] as? [[String: Any]] ?? []
    if !items.isEmpty {
        lines.append("")
        lines.append("Items:")
        for item in items {
            var text = "- " + orderItemLineText(item, modelNames: modelNames)
            if let material = orderItemMaterialName(item, filaments: filaments) { text += " (\(material))" }
            lines.append(text)
        }
    }
    let description = details.trimmingCharacters(in: .whitespacesAndNewlines)
    if !description.isEmpty {
        lines.append("")
        lines.append("What happened:")
        lines.append(description)
    }
    lines.append("")
    lines.append("Thank you.")
    return lines.joined(separator: "\n")
}

/// The problems that fit the order's status, "Other" last and always offered: late while it's being made or on its
/// way; damaged, wrong, missing or a print defect only once it has shipped or been delivered.
func orderProblemKinds(status: String) -> [OrderProblemKind] {
    let normalized = status.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    var kinds: [OrderProblemKind] = []
    if ["SHIPPED", "DELIVERED"].contains(normalized) { kinds += [.damaged, .wrongItem, .missingItem, .printDefect] }
    if orderAttentionProductionStatuses.contains(normalized) || normalized == "SHIPPED" { kinds.append(.late) }
    return kinds + [.other]
}

/// The detail's Report a Problem… button is offered once an order has been placed: a draft has nothing to report.
func orderOffersProblemReport(status: String) -> Bool {
    let normalized = status.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    return !normalized.isEmpty && normalized != "DRAFT"
}

/// Reprint as New Draft…'s help: what opens, and that the draft names the order it reprints.
func orderReprintButtonHelp(orderNumber: String) -> String {
    let number = orderNumber.trimmingCharacters(in: .whitespacesAndNewlines)
    let link = number.isEmpty ? "" : " The draft is marked as a reprint of order \(number) (reprintOf in its reference fields)."
    return "Close this and open a new draft with this order’s items and delivery details for review." + link
        + " Nothing is created until you choose Create Draft."
}

struct OrderProblemReportRequest: Identifiable {
    let id: String
    let order: [String: Any]
}

struct OrderProblemReportSheet: View {
    @EnvironmentObject var store: StudioStore
    @Environment(\.dismiss) var dismiss
    let order: [String: Any]
    /// Closes this sheet and then opens Duplicate as New Draft's path for the order as a reprint: the same composer,
    /// whose draft also carries `metadata.reprintOf` (`orderMetadataAddingReprintOf`).
    let onReprint: () -> Void
    @State private var problem: OrderProblemKind?
    @State private var details = ""
    @State private var copied = false

    var orderID: String { Record(values: order).id }
    var message: String? {
        problem.map {
            orderProblemMessage(order: order, problem: $0, details: details,
                                modelNames: orderItemModelNames(localModels: store.localModels, files: store.files),
                                filaments: store.filaments)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Report a problem").font(.title2.weight(.bold))
            Text(orderProblemReportCaption)
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            Picker("Problem", selection: $problem) {
                Text("Choose…").tag(OrderProblemKind?.none)
                // From the status shown (`orderDisplayStatus`): an order Slant's shipping record says shipped can
                // also be damaged, wrong or missing.
                ForEach(orderProblemKinds(status: orderDisplayStatus(order))) { Text($0.title).tag(OrderProblemKind?.some($0)) }
            }
            .fixedSize()
            // Late delivery: whether the delay is at Slant or with the carrier (`orderLateStage`), at Slant against the
            // seller's own usual time to a shipping label (default platform only).
            if let guidance = problem.flatMap({ orderProblemGuidance($0, order: order, typical: store.orderShipTimeSummary(for: store.orders)) }) {
                Label(guidance, systemImage: "info.circle").font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // With the carrier: its tracking page, opened in the browser only on this click; Plinth sends nothing.
            if let carrier = orderProblemTrackingCarrier(problem, order: order), let url = carrier.trackingURL {
                Button("Track Parcel") { NSWorkspace.shared.open(url) }
                    .help("Open \(carrier.name)’s tracking page for this order in your browser")
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("What happened")
                TextEditor(text: $details)
                    .font(.body)
                    .frame(height: 90)
                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.secondary.opacity(0.3)))
                    .accessibilityLabel("What happened")
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Message").foregroundStyle(.secondary)
                // A fixed-height box, never a measuring layout.
                ScrollView {
                    Text(message ?? "Choose the problem to see the message.")
                        .font(.callout)
                        .foregroundStyle(message == nil ? .secondary : .primary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }
                .frame(height: 150)
                .background(Color(nsColor: .textBackgroundColor).opacity(0.6))
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.secondary.opacity(0.3)))
            }
            Spacer(minLength: 0)
            HStack {
                Button("Close", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                let reprintBlocked = store.duplicateOrderBlockedReason(orderID: orderID)
                Button("Reprint as New Draft…") { onReprint() }
                    .disabled(reprintBlocked != nil || orderID.isEmpty)
                    .help(reprintBlocked ?? orderReprintButtonHelp(orderNumber: orderNumber(order)))
                Spacer()
                if copied { Text("Copied.").font(.caption).foregroundStyle(.secondary) }
                Button("Copy Message") {
                    guard let message else { return }
                    copyToPasteboard(message)
                    copied = true
                }
                .buttonStyle(.borderedProminent)
                .disabled(message == nil)
                .help(message == nil ? "Choose the problem first" : "Copy the message to paste into your message to Slant")
            }
        }
        .padding(24)
        .frame(width: 540, height: 680)
        .onChange(of: problem) { copied = false }
        .onChange(of: details) { copied = false }
    }
}

// MARK: Review next draft

/// The draft to review after `currentID`, in the order the list shows: the first DRAFT below the current order that
/// isn't the current one and isn't held by the unknown-outcome lock. With no current order (or one no longer listed),
/// the first such draft from the top. Nil at the end of the list; it never wraps round. Only chooses which review
/// to open: that review re-fetches the order, requires DRAFT and needs its own Pay press.
func orderNextDraftToReview(rows: [(id: String, status: String)], after currentID: String?,
                            isLocked: (String) -> Bool) -> String? {
    let startIndex: Int
    if let currentID, let index = rows.firstIndex(where: { $0.id == currentID }) {
        startIndex = index + 1
    } else {
        startIndex = 0
    }
    guard startIndex < rows.count else { return nil }
    return rows[startIndex...].first { row in
        !row.id.isEmpty && row.id != currentID
            && row.status.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() == "DRAFT"
            && !isLocked(row.id)
    }?.id
}

/// The caption beside Review Next Draft, naming the next order so the seller knows which review opens.
func orderNextDraftCaption(recipient: String, number: String) -> String {
    let name = recipient.trimmingCharacters(in: .whitespacesAndNewlines)
    let id = number.trimmingCharacters(in: .whitespacesAndNewlines)
    switch (name.isEmpty || name == "Order", id.isEmpty) {
    case (false, false): return "Next: \(name) · \(id)"
    case (false, true): return "Next: \(name)"
    case (true, false): return "Next: \(id)"
    case (true, true): return "Next: another draft"
    }
}

/// The list as it was when the first review opened (`snapshotIDs`, in the order shown then), with each order's status
/// from the loaded orders now. An order no longer loaded gets no status, so it's skipped. Re-sorting, Needs attention
/// or a paid draft leaving the list therefore can't move the review's place or make it wrap round.
func orderDraftReviewRows(snapshotIDs: [String], orders: [Record]) -> [(id: String, status: String)] {
    var statuses: [String: String] = [:]
    for row in orderDraftReviewRows(orders) where statuses[row.id] == nil { statuses[row.id] = row.status }
    return snapshotIDs.map { (id: $0, status: statuses[$0] ?? "") }
}

/// The drafts a run of reviews can reach, in list order, when it begins: unlocked DRAFT rows, each once. Only counts
/// for "Draft 2 of 5"; which review opens next is still `orderNextDraftToReview`'s choice.
func orderReviewRunDraftIDs(rows: [(id: String, status: String)], isLocked: (String) -> Bool) -> [String] {
    var seen = Set<String>()
    return rows.compactMap { row in
        guard !row.id.isEmpty, row.status.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() == "DRAFT",
              !isLocked(row.id), seen.insert(row.id).inserted else { return nil }
        return row.id
    }
}

/// "Draft 2 of 5" for the review of `current`, or nil when the run has a single draft or doesn't include it.
func orderReviewRunPositionText(draftIDs: [String], current: String) -> String? {
    guard draftIDs.count > 1, let index = draftIDs.firstIndex(of: current) else { return nil }
    return "Draft \(index + 1) of \(draftIDs.count)"
}

/// Whether the charge review offers the next draft: Review Next Draft… once this order is placed, or Skip to Next
/// Draft… during a run before Pay is pressed. Never while a Pay is being sent or after one whose result is unknown.
func orderReviewOffersNextDraft(inRun: Bool, writeSucceeded: Bool, writeAttempted: Bool, writing: Bool) -> Bool {
    if writing { return false }
    if writeSucceeded { return true }
    return inRun && !writeAttempted
}

/// The list's orders, in the order shown, as the ID and Slant status that `orderNextDraftToReview` reads.
func orderDraftReviewRows(_ records: [Record]) -> [(id: String, status: String)] {
    records.map { record in
        (id: record.id, status: (orderObject(record.values)["status"] as? String) ?? record.string("status"))
    }
}
