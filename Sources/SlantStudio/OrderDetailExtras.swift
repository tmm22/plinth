import Foundation
import SwiftUI

// MARK: - Order detail extras
//
// Display-only additions to the order detail: per-item production progress, a label-address check, a support message
// to copy, and the "Review Next Draft" step between charge reviews. Nothing here sends a request, pays, saves order
// data or touches the unknown-outcome lock; paying still happens only through `OrderActionConfirmSheet`.

// MARK: Production progress (unverified fields)

/// Order statuses whose production progress isn't worth showing: drafts haven't started (Slant reports their items as
/// PROCESSING with no assignments, seen 23 Oct 2026), and cancelled, shipped or delivered orders are past it.
let orderProgressHiddenStatuses: Set<String> = ["DRAFT", "CANCELED", "CANCELLED", "SHIPPED", "DELIVERED", "PAYMENT_ERROR"]

/// One item's production progress from Slant's documented `estimatedPrintCompletion` and `assignments` fields. The
/// bundled OpenAPI doesn't list either, so both are read defensively and nothing is shown when they're absent.
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

/// One caption line: "Printing · estimated done 24 Oct, 15:10", "On the shelf" or "Estimated done 24 Oct".
func orderItemProgressLine(_ progress: OrderItemProgress, now: Date = Date(),
                           locale: Locale = .current, timeZone: TimeZone = .current) -> String? {
    let estimate = progress.estimatedCompletion.map {
        orderProgressDateText($0, dateOnly: progress.estimateIsDateOnly, now: now, locale: locale, timeZone: timeZone)
    }
    switch (progress.stage, estimate) {
    case (let stage?, let estimate?): return "\(stage) · estimated done \(estimate)"
    case (let stage?, nil): return stage
    case (nil, let estimate?): return "Estimated done \(estimate)"
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

/// Reads an address object, accepting Slant's `line1`/`zip` and the label providers' usual `street1`/`postalCode`
/// spellings, since the fulfillment address's shape isn't documented beyond "address the label was generated against".
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
/// Display only: neither address is stored.
func orderLabelAddressAdvisory(_ order: [String: Any]) -> (line: String, differences: [String])? {
    guard let rawLabel = (order["fulfillment"] as? [String: Any])?["address"] as? [String: Any],
          let label = orderComparableAddress(rawLabel),
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
    return ("Slant’s label address differs: " + parts.joined(separator: ", "), differences)
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

/// Neither the repository's docs nor the bundled OpenAPI name a Slant support address or page (the OpenAPI
/// `info.contact` is the API's developer contact), so the sheet offers Copy only and never opens a mail link.
let orderProblemReportCaption = "Studio puts together a message with this order’s details for you to send to Slant support. It doesn’t send anything itself: copy the message and paste it into your email or support request. Names and addresses aren’t included."

/// The support message: order number, status, created date, tracking numbers, items with quantities and materials,
/// the problem and the seller's description. No recipient name, email or address.
func orderProblemMessage(order: [String: Any], problem: OrderProblemKind, details: String,
                         modelNames: [String: String] = [:], filaments: [Record] = []) -> String {
    let number = orderNumber(order)
    let reference = number.isEmpty ? "my order" : "order \(number)"
    var lines = ["Hello Slant team,", "", "I’d like to report a problem with \(reference): \(problem.title.lowercased()).", ""]
    if !number.isEmpty { lines.append("Order number: \(number)") }
    let status = (order["status"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    if !status.isEmpty { lines.append("Status: \(orderStatusTitle(status))") }
    if let created = orderCreatedDisplay(order) { lines.append("Created: \(created)") }
    for (label, value) in trackingFacts(order["fulfillment"]) where label == "Tracking number" {
        lines.append("Tracking number: \(value)")
    }
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

/// The detail's Report a Problem… button is offered once an order has been placed: a draft has nothing to report.
func orderOffersProblemReport(status: String) -> Bool {
    let normalized = status.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    return !normalized.isEmpty && normalized != "DRAFT"
}

struct OrderProblemReportRequest: Identifiable {
    let id: String
    let order: [String: Any]
}

struct OrderProblemReportSheet: View {
    @EnvironmentObject var store: StudioStore
    @Environment(\.dismiss) var dismiss
    let order: [String: Any]
    /// Closes this sheet and then opens the normal Duplicate as New Draft path for the order.
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
            Picker("Problem", selection: $problem) {
                Text("Choose…").tag(OrderProblemKind?.none)
                ForEach(OrderProblemKind.allCases) { Text($0.title).tag(OrderProblemKind?.some($0)) }
            }
            .fixedSize()
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
                    .help(reprintBlocked ?? "Close this and open a new draft with this order’s items and delivery details for review. Nothing is created until you choose Create Draft.")
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
        .frame(width: 540, height: 580)
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

/// The list's orders, in the order shown, as the ID and Slant status that `orderNextDraftToReview` reads.
func orderDraftReviewRows(_ records: [Record]) -> [(id: String, status: String)] {
    records.map { record in
        (id: record.id, status: (orderObject(record.values)["status"] as? String) ?? record.string("status"))
    }
}
