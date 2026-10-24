import Foundation
import CoreGraphics

// MARK: - What the buyer paid, from Import Orders
//
// Etsy's "Sold Order Items" file and Shopify's orders export say what each buyer paid. When Import Orders creates a
// draft, those amounts (USD only) are kept IN MEMORY for the app session, keyed by the new Slant order ID, so the
// order's Profit check starts filled in and the pay review can show an estimated profit. They are never written to
// disk, preferences, logs or Activity, and are dropped on Disconnect or a key change.
//
// Amounts are read strictly and only when the file leaves no doubt; anything unclear is left for the seller to type,
// with a note saying why. Taxes aren't read: the Profit check leaves them out.

/// The raw sale columns of one CSV row, as written in the file.
struct OrderImportSaleRow: Equatable {
    var currency = ""
    /// Etsy, per item row: unit price, quantity, the row's item total and discount.
    var price = ""
    var quantity = ""
    var itemTotal = ""
    var discount = ""
    /// Etsy: shipping and shipping discount (order-level names, but given on item rows).
    var shipping = ""
    var shippingDiscount = ""
    /// Shopify, order level (first row of the order): subtotal, taxes, total and refunds. `shipping` and `discount`
    /// hold Shopify's Shipping and Discount Amount.
    var subtotal = ""
    var taxes = ""
    var total = ""
    var refunded = ""
}

/// The row's sale columns, or nil when it has none (for example Shopify's follow-on item rows).
func orderImportSaleRow(_ value: (OrderImportField) -> String) -> OrderImportSaleRow? {
    let row = OrderImportSaleRow(
        currency: value(.saleCurrency), price: value(.salePrice), quantity: value(.quantity),
        itemTotal: value(.saleItemTotal), discount: value(.saleDiscount), shipping: value(.saleShipping),
        shippingDiscount: value(.saleShippingDiscount), subtotal: value(.saleSubtotal), taxes: value(.saleTaxes),
        total: value(.saleTotal), refunded: value(.saleRefunded))
    let amounts = [row.currency, row.price, row.itemTotal, row.discount, row.shipping, row.shippingDiscount,
                   row.subtotal, row.taxes, row.total, row.refunded]
    return amounts.allSatisfy(\.isEmpty) ? nil : row
}

/// What one imported order's buyer paid, in USD. A nil amount is one the file didn't make clear.
struct ImportedSaleAmounts: Equatable {
    let source: OrderImportFormat
    let sourceOrderID: String
    /// Items after discounts, before shipping and taxes.
    var itemTotal: Decimal?
    var shipping: Decimal?
    /// Marketplace units bought (the order's item quantities added up), for per-unit listing fees.
    var unitsSold: Int?
    /// Why an amount wasn't filled in, or what it leaves out.
    var notes: [String] = []
}

enum ImportedSaleParse: Equatable {
    case amounts(ImportedSaleAmounts)
    /// Amounts in another currency: not kept, because the Profit check works in USD.
    case otherCurrency(String)
    /// No amounts, no currency, or nothing usable.
    case none
}

/// Reads an imported order's sale amounts. Only USD is kept, and only when the currency is stated.
func importedSaleAmounts(for order: OrderImportOrder) -> ImportedSaleParse {
    let rows = order.saleRows
    guard !rows.isEmpty else { return .none }
    let currencies = Set(rows.map { $0.currency.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() }.filter { !$0.isEmpty })
    guard currencies.count == 1, let currency = currencies.first else { return .none }
    guard currency == "USD" else { return .otherCurrency(currency) }
    var amounts = ImportedSaleAmounts(source: order.source, sourceOrderID: order.sourceOrderID)
    switch order.source {
    case .etsy: importedEtsyAmounts(rows, itemCount: order.items.count, into: &amounts)
    case .shopify: importedShopifyAmounts(rows, into: &amounts)
    case .template: return .none
    }
    amounts.unitsSold = importedSaleUnits(order.items)
    guard amounts.itemTotal != nil || amounts.shipping != nil else { return .none }
    return .amounts(amounts)
}

/// A money cell: blank is nil, otherwise strictly parsed (Margin.swift), with CSV exports' "." decimal mark.
enum ImportedSaleCell: Equatable {
    case blank
    case value(Decimal)
    case invalid
}

func importedSaleCell(_ text: String) -> ImportedSaleCell {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return .blank }
    guard let value = parseProfitAmount(trimmed, decimalSeparator: ".") else { return .invalid }
    return .value(roundedToCents(value))
}

enum ImportedSaleOrderAmount: Equatable {
    case value(Decimal)
    /// Blank on every row.
    case missing
    /// Every row repeats the same non-zero amount: it could be the order's amount or each item's share.
    case ambiguous
    case invalid
}

/// An Etsy amount given on each item row under an order-level name (Order Shipping, Discount Amount, Shipping
/// Discount). Etsy's documentation doesn't say whether it's the order's amount repeated or each item's share, so: one
/// row, or one non-zero row, gives the amount; different non-zero amounts are shares and are added up; the same
/// non-zero amount on every one of several rows could be either, so it isn't guessed.
func importedEtsyOrderAmount(_ texts: [String]) -> ImportedSaleOrderAmount {
    var values: [Decimal] = []
    for text in texts {
        switch importedSaleCell(text) {
        case .blank: values.append(0)
        case .value(let value): values.append(value)
        case .invalid: return .invalid
        }
    }
    guard texts.contains(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else { return .missing }
    let nonZero = values.filter { $0 > 0 }
    if nonZero.count <= 1 { return .value(nonZero.first ?? 0) }
    if nonZero.count == values.count, Set(nonZero).count == 1 { return .ambiguous }
    return .value(nonZero.reduce(0, +))
}

private func importedEtsyAmounts(_ rows: [OrderImportSaleRow], itemCount: Int, into amounts: inout ImportedSaleAmounts) {
    // Every item row must carry its amounts, or the item total would be understated.
    if rows.count == itemCount {
        amounts.itemTotal = importedEtsyItemTotal(rows, notes: &amounts.notes)
    } else {
        amounts.notes.append("Enter the item total: some of this order’s rows have no amounts.")
    }
    switch importedEtsyOrderAmount(rows.map(\.shippingDiscount)) {
    case .value(0), .missing:
        switch importedEtsyOrderAmount(rows.map(\.shipping)) {
        case .value(let shipping): amounts.shipping = shipping
        case .ambiguous:
            amounts.notes.append("Enter the shipping charged: Etsy’s file shows the same shipping on each item of this order, so the order’s shipping isn’t clear.")
        case .missing, .invalid:
            amounts.notes.append("Enter the shipping charged: Etsy’s file doesn’t show it clearly.")
        }
    default:
        amounts.notes.append("Enter the shipping the buyer paid: Etsy shows a shipping discount on this order.")
    }
}

/// Price × quantity for each row, less the order's discount. Each row's Item Total, when given, must agree (either
/// before or after that row's discount), or nothing is filled in.
private func importedEtsyItemTotal(_ rows: [OrderImportSaleRow], notes: inout [String]) -> Decimal? {
    let unclear = "Enter the item total: Etsy’s amounts for this order don’t add up clearly."
    var gross: Decimal = 0
    for row in rows {
        let itemTotal = importedSaleCell(row.itemTotal)
        let discount = importedSaleCell(row.discount)
        guard discount != .invalid, itemTotal != .invalid else { notes.append(unclear); return nil }
        if case .value(let price) = importedSaleCell(row.price), let quantity = orderImportQuantity(row.quantity) {
            let line = roundedToCents(price * Decimal(quantity))
            if case .value(let stated) = itemTotal {
                var rowDiscount: Decimal = 0
                if case .value(let value) = discount { rowDiscount = value }
                guard stated == line || stated == line - rowDiscount else { notes.append(unclear); return nil }
            }
            gross += line
        } else {
            notes.append(unclear)
            return nil
        }
    }
    switch importedEtsyOrderAmount(rows.map(\.discount)) {
    case .value(let discount):
        guard gross - discount >= 0 else { notes.append(unclear); return nil }
        return gross - discount
    case .missing:
        return gross
    case .ambiguous:
        notes.append("Enter the item total: Etsy’s file shows the same discount on each item of this order, so the order’s discount isn’t clear.")
        return nil
    case .invalid:
        notes.append(unclear)
        return nil
    }
}

/// Shopify gives order-level amounts on the order's first row and leaves them blank on its other item rows.
enum ImportedShopifyAmount: Equatable {
    case value(Decimal)
    case missing
    /// Rows disagree, or a value isn't a plain amount.
    case invalid
}

func importedShopifyOrderAmount(_ texts: [String]) -> ImportedShopifyAmount {
    var found: Decimal?
    for text in texts {
        switch importedSaleCell(text) {
        case .blank: continue
        case .invalid: return .invalid
        case .value(let value):
            if let found, found != value { return .invalid }
            found = value
        }
    }
    return found.map(ImportedShopifyAmount.value) ?? .missing
}

/// Subtotal and Shipping, checked against Total: Total is subtotal + shipping (+ taxes, unless prices include them),
/// with the discount already out of the subtotal or (when the Total says so) still to come off it.
private func importedShopifyAmounts(_ rows: [OrderImportSaleRow], into amounts: inout ImportedSaleAmounts) {
    func amount(_ keyPath: KeyPath<OrderImportSaleRow, String>) -> ImportedShopifyAmount {
        importedShopifyOrderAmount(rows.map { $0[keyPath: keyPath] })
    }
    guard case .value(let subtotal) = amount(\.subtotal) else {
        amounts.notes.append("Enter the item total: Shopify’s subtotal for this order isn’t clear.")
        return
    }
    var shipping: Decimal?
    if case .value(let value) = amount(\.shipping) { shipping = value }
    var taxes: Decimal?
    switch amount(\.taxes) {
    case .value(let value): taxes = value
    case .missing: taxes = 0
    case .invalid: taxes = nil
    }
    var discount: Decimal = 0
    if case .value(let value) = amount(\.discount) { discount = value }
    if case .value(let total) = amount(\.total) {
        guard let shipping, let taxes else {
            amounts.itemTotal = subtotal
            amounts.notes.append("Enter the shipping charged: Shopify’s file doesn’t show it clearly.")
            return
        }
        if total == subtotal + shipping + taxes || total == subtotal + shipping {
            amounts.itemTotal = subtotal
            amounts.shipping = shipping
        } else if discount > 0, discount <= subtotal,
                  total == subtotal - discount + shipping + taxes || total == subtotal - discount + shipping {
            amounts.itemTotal = subtotal - discount
            amounts.shipping = shipping
        } else {
            amounts.itemTotal = subtotal
            amounts.notes.append("Enter the shipping the buyer paid: Shopify’s total for this order isn’t its subtotal, shipping and taxes added up (it may include duties or a shipping discount).")
        }
    } else {
        amounts.itemTotal = subtotal
        if let shipping {
            amounts.shipping = shipping
        } else {
            amounts.notes.append("Enter the shipping charged: Shopify’s file doesn’t show it clearly.")
        }
    }
    if case .value(let refunded) = amount(\.refunded), refunded > 0 {
        amounts.notes.append("Shopify shows \(money(NSDecimalNumber(decimal: refunded))) refunded on this order; the amounts here don’t take it off.")
    }
}

/// The order's item quantities added up, or nil when one isn't a whole number or the sum is implausible.
func importedSaleUnits(_ items: [OrderImportItem]) -> Int? {
    guard !items.isEmpty else { return nil }
    var units = 0
    for item in items {
        guard let quantity = orderImportQuantity(item.quantityText) else { return nil }
        units += quantity
    }
    return units <= profitUnitsSoldLimit ? units : nil
}

/// The amounts for each order of a file that has any, by import row ID. Orders in `leavingOutItemsIn` (row IDs whose
/// drafts leave items out under Match products) keep only what still applies (`importedSaleAmountsForDraft`).
func importedSaleAmountsByOrder(_ orders: [OrderImportOrder], leavingOutItemsIn leftOut: Set<String> = []) -> [String: ImportedSaleAmounts] {
    var result: [String: ImportedSaleAmounts] = [:]
    for order in orders {
        guard case .amounts(let amounts) = importedSaleAmounts(for: order),
              let kept = importedSaleAmountsForDraft(amounts, leavesOutItems: leftOut.contains(order.id)) else { continue }
        result[order.id] = kept
    }
    return result
}

let importedSaleLeftOutNote = "Some items weren’t in this draft, so enter what the buyer paid for the rest."

/// The amounts to keep for a draft. When Match products left some of the order's items out of the draft, the buyer's
/// item total and units cover items Slant isn't making, and would overstate the profit: they're dropped, with a note,
/// and only the shipping charged is kept. Nil when nothing is left to keep.
func importedSaleAmountsForDraft(_ amounts: ImportedSaleAmounts, leavesOutItems: Bool) -> ImportedSaleAmounts? {
    guard leavesOutItems else { return amounts }
    var kept = amounts
    kept.itemTotal = nil
    kept.unitsSold = nil
    // Notes about the item total no longer apply; the left-out note says what to enter instead.
    kept.notes = [importedSaleLeftOutNote] + amounts.notes.filter { !$0.hasPrefix("Enter the item total") }
    return kept.shipping == nil ? nil : kept
}

/// The import sheet's note on what happens to the amounts buyers paid, or nil when the file has none.
func orderImportSaleAmountsNotice(_ orders: [OrderImportOrder]) -> String? {
    var usd = 0
    var other: [String] = []
    for order in orders {
        switch importedSaleAmounts(for: order) {
        case .amounts: usd += 1
        case .otherCurrency(let code): if !other.contains(code) { other.append(code) }
        case .none: break
        }
    }
    var parts: [String] = []
    if usd > 0 {
        parts.append("What buyers paid is kept in memory until you quit, disconnect or change your API key, to fill in each new draft’s Profit check. It isn’t saved or sent to Slant.")
    }
    if !other.isEmpty {
        let codes = other.sorted().prefix(3).joined(separator: ", ")
        parts.append("Amounts in \(codes) aren’t used: the Profit check works in US dollars.")
    }
    return parts.isEmpty ? nil : parts.joined(separator: " ")
}

/// The imported amounts kept for a loaded Slant order, matched by any of its IDs.
func importedSaleAmountsLookup(_ amounts: [String: ImportedSaleAmounts], order: [String: Any]) -> ImportedSaleAmounts? {
    guard !amounts.isEmpty else { return nil }
    var ids = [Record(values: order).id]
    for key in ["publicId", "id"] { if let id = order[key] as? String { ids.append(id) } }
    for id in ids {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty, let found = amounts[trimmed] { return found }
    }
    return nil
}

// MARK: Profit check prefill

/// The Profit check's caption for prefilled amounts, such as "From the imported Etsy order T-1001 (this session only)."
func importedSaleCaption(_ amounts: ImportedSaleAmounts) -> String {
    let label = orderMarketplaceReferenceLabel(source: amounts.source.rawValue)
    let lead = label == "Imported order" ? "From imported order" : "From the imported \(label)"
    return ([lead + " \(amounts.sourceOrderID) (this session only). Edit them if they differ."] + amounts.notes).joined(separator: " ")
}

/// A prefilled amount as the field shows it: two decimals, in the Mac's decimal mark.
func importedSaleFieldText(_ value: Decimal, decimalSeparator: String = Locale.current.decimalSeparator ?? ".") -> String {
    let formatter = NumberFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.numberStyle = .decimal
    formatter.usesGroupingSeparator = false
    formatter.minimumFractionDigits = 2
    formatter.maximumFractionDigits = 2
    let text = formatter.string(from: NSDecimalNumber(decimal: roundedToCents(value))) ?? profitRateText(value)
    return decimalSeparator == "," ? text.replacingOccurrences(of: ".", with: ",") : text
}

/// What the Profit check's fields become from imported amounts: each is replaced only while still empty (units
/// while still the default 1). Nil fields stay as they are.
struct ImportedSalePrefill: Equatable {
    var itemText: String?
    var shippingText: String?
    var unitsText: String?
}

func importedSalePrefill(_ amounts: ImportedSaleAmounts, itemText: String, shippingText: String, unitsText: String,
                         decimalSeparator: String = Locale.current.decimalSeparator ?? ".") -> ImportedSalePrefill {
    var prefill = ImportedSalePrefill()
    func isEmpty(_ text: String) -> Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    if isEmpty(itemText), let item = amounts.itemTotal {
        prefill.itemText = importedSaleFieldText(item, decimalSeparator: decimalSeparator)
    }
    if isEmpty(shippingText), let shipping = amounts.shipping {
        prefill.shippingText = importedSaleFieldText(shipping, decimalSeparator: decimalSeparator)
    }
    let units = unitsText.trimmingCharacters(in: .whitespacesAndNewlines)
    if units.isEmpty || units == "1", let sold = amounts.unitsSold {
        prefill.unitsText = String(sold)
    }
    return prefill
}

// MARK: Pay review

struct ImportedSaleReviewEstimate: Equatable {
    let text: String
    let isLoss: Bool
}

/// The pay review's one-line estimate from imported amounts, the fresh Slant total and the saved fee preset and
/// rates (no Offsite Ads, which the seller ticks per order in the Profit check). Nil unless the order is a draft with
/// a usable USD total and both amounts are known (and the units, when the fees include a per-unit listing fee).
/// Informational only: it never affects whether Pay is enabled.
func importedSaleReviewEstimate(_ amounts: ImportedSaleAmounts?, order: [String: Any], preset: ProfitFeePreset,
                                rates: ProfitFeeRates) -> ImportedSaleReviewEstimate? {
    guard let amounts, let item = amounts.itemTotal, let shipping = amounts.shipping,
          ((order["status"] as? String) ?? "").uppercased() == "DRAFT",
          case .amount(let slantTotal) = profitCheckSlantTotal(order) else { return nil }
    let listingFee = preset.hasRates && preset != .shopifyBasicUS && rates.listingFeePerItem > 0
    guard !listingFee || amounts.unitsSold != nil else { return nil }
    let result = profitCheck(itemTotal: item, shippingCharged: shipping, preset: preset, rates: rates, offsiteAds: false,
                             unitsSold: amounts.unitsSold ?? 1, slantTotal: slantTotal)
    let margin = result.marginPercent.map { value -> String in
        value < 0 ? " (−\(profitRateText(-value))%)" : " (\(profitRateText(value))%)"
    } ?? ""
    let basis = preset.hasRates ? "at your saved fee rates" : "before marketplace fees"
    if result.profit < 0 {
        return ImportedSaleReviewEstimate(text: "This order would lose about \(profitMoney(-result.profit))\(margin) \(basis)", isLoss: true)
    }
    return ImportedSaleReviewEstimate(text: "Estimated profit: \(profitMoney(result.profit))\(margin) \(basis)", isLoss: false)
}

/// The pay review's item list when the receipt has extra lines (the marketplace reference, the estimated profit). The
/// sheet has a fixed height, so each extra line takes one item's worth of the list's space: fewer items are listed
/// plainly and the scrolling box is shorter, keeping the buttons in view. Chosen by counts, never by measuring.
let orderReviewItemBoxHeight: CGFloat = 128
let orderReviewExtraLineHeight: CGFloat = 21

func orderReviewItemListLayout(itemCount: Int, extraReceiptLines: Int) -> (scrolls: Bool, height: CGFloat) {
    let extras = max(0, min(2, extraReceiptLines))
    return (itemCount > orderReviewPlainItemLimit - extras,
            orderReviewItemBoxHeight - CGFloat(extras) * orderReviewExtraLineHeight)
}
