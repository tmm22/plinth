import Foundation

// MARK: - Which Shopify order, and which of its items, a Slant draft is
//
// Order names ("#1001") repeat across stores, and a Slant draft may hold only some of a Shopify order's items (Match
// products' Leave out, or a second draft for the rest). So Import Orders records two more metadata fields on Shopify
// drafts, and Send Tracking to Shopify uses them before it fulfils anything:
//   - `sourceShop`: the store's myshopify.com address, for orders fetched with Fetch from Shopify. A draft from another
//     store is never sent. CSV imports don't know the store, so their Shopify order must match the Slant order's
//     recipient name and postcode (compared in memory, never saved) before it can be ticked.
//   - `sourceItems`: the Shopify items the draft was made from and their units, as a short JSON string. Only those
//     units are marked as fulfilled; anything that can't be matched exactly blocks the order instead.
// With `source`, `sourceOrderId` and `studioDraftId` that is 5 of Slant's 10 metadata fields.

/// Longest `sourceItems` value Studio writes or reads. An order whose items don't fit is drafted without it, and its
/// tracking is then added in Shopify by hand.
let shopifySourceItemsMaxLength = 1_000
/// Most entries `sourceItems` holds.
let shopifySourceItemsMaxCount = 60

/// One Shopify item a draft holds: identified by its line item ID (Fetch from Shopify), else its SKU, else its name
/// (a CSV export has no line item IDs).
struct ShopifySourceItem: Equatable {
    enum Key: Equatable {
        /// The numeric part of `gid://shopify/LineItem/…`.
        case lineItem(String)
        /// As written, trimmed; compared with `normalizedSKU`.
        case sku(String)
        /// As written, with repeated spaces collapsed; compared ignoring case.
        case name(String)
    }
    let key: Key
    let quantity: Int
}

/// The numeric ID in a Shopify GID such as `gid://shopify/LineItem/123`, or nil.
func shopifyNumericID(_ gid: String, type: String) -> String? {
    let prefix = "gid://shopify/\(type)/"
    let trimmed = gid.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.hasPrefix(prefix) else { return nil }
    let digits = String(trimmed.dropFirst(prefix.count).prefix { $0 != "?" })
    guard !digits.isEmpty, digits.count <= 20, digits.allSatisfy(\.isASCII), digits.allSatisfy(\.isNumber) else { return nil }
    return digits
}

private func shopifyCollapsedName(_ name: String) -> String {
    name.split(whereSeparator: \.isWhitespace).joined(separator: " ")
}

/// The Shopify items a draft is made from, with repeated keys added up. Nil when an item has no line item ID, SKU or
/// name, or a quantity that isn't a whole number from 1 to 10,000: its tracking can't then be matched safely.
func shopifySourceItems(_ items: [OrderImportItem]) -> [ShopifySourceItem]? {
    var result: [ShopifySourceItem] = []
    for item in items {
        guard let units = orderImportQuantity(item.quantityText) else { return nil }
        let key: ShopifySourceItem.Key
        let sku = item.sku.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = shopifyCollapsedName(item.itemName)
        if !item.sourceLineItemID.isEmpty {
            key = .lineItem(item.sourceLineItemID)
        } else if !sku.isEmpty {
            key = .sku(sku)
        } else {
            // Never keyed by name: a per-buyer variant title ("Necklace - Sarah") could carry the buyer's text into
            // Slant's metadata. Such orders have no recorded items, so their tracking is added in Shopify by hand.
            _ = name
            return nil
        }
        if let index = result.firstIndex(where: { shopifySourceKeysMatch($0.key, key) }) {
            result[index] = ShopifySourceItem(key: result[index].key, quantity: result[index].quantity + units)
        } else {
            result.append(ShopifySourceItem(key: key, quantity: units))
        }
    }
    return result.isEmpty ? nil : result
}

private func shopifySourceKeysMatch(_ lhs: ShopifySourceItem.Key, _ rhs: ShopifySourceItem.Key) -> Bool {
    switch (lhs, rhs) {
    case (.lineItem(let a), .lineItem(let b)): return a == b
    case (.sku(let a), .sku(let b)): return normalizedSKU(a) == normalizedSKU(b)
    case (.name(let a), .name(let b)): return shopifyCollapsedName(a).lowercased() == shopifyCollapsedName(b).lowercased()
    default: return false
    }
}

/// The `sourceItems` metadata value: compact JSON with sorted keys, or nil when there's nothing to record or it would
/// be longer than `shopifySourceItemsMaxLength`.
func shopifySourceItemsMetadata(_ items: [ShopifySourceItem]?) -> String? {
    guard let items, !items.isEmpty, items.count <= shopifySourceItemsMaxCount else { return nil }
    let list: [[String: Any]] = items.map { item in
        switch item.key {
        case .lineItem(let id): return ["lineItem": id, "quantity": item.quantity]
        case .sku(let sku): return ["sku": sku, "quantity": item.quantity]
        case .name(let name): return ["name": name, "quantity": item.quantity]
        }
    }
    guard let data = try? JSONSerialization.data(withJSONObject: list, options: [.sortedKeys]),
          let text = String(data: data, encoding: .utf8), text.count <= shopifySourceItemsMaxLength else { return nil }
    return text
}

/// A Shopify draft's `sourceItems`: the order's items that the draft holds (`itemProductIDs`, parallel to the items,
/// is nil for an item left out under Match products; nil altogether means every item). Nil for other sources.
func shopifyDraftSourceItems(_ order: OrderImportOrder, itemProductIDs: [UUID?]?) -> String? {
    guard order.source == .shopify else { return nil }
    let included = order.items.indices.filter { index in
        guard let itemProductIDs else { return true }
        return index < itemProductIDs.count && itemProductIDs[index] != nil
    }.map { order.items[$0] }
    return shopifySourceItemsMetadata(shopifySourceItems(included))
}

/// Reads `sourceItems` back. Nil when absent or anything in it is unexpected: a partly readable list is never used.
func shopifySourceItems(fromMetadata value: Any?) -> [ShopifySourceItem]? {
    guard let text = value as? String, !text.isEmpty, text.count <= shopifySourceItemsMaxLength * 2,
          let list = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [[String: Any]],
          !list.isEmpty, list.count <= shopifySourceItemsMaxCount else { return nil }
    var items: [ShopifySourceItem] = []
    for entry in list {
        guard let number = entry["quantity"] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue == Double(number.intValue), (1...10_000).contains(number.intValue) else { return nil }
        let keys = ["lineItem", "sku", "name"].filter { entry[$0] != nil }
        guard keys.count == 1, let raw = entry[keys[0]] as? String else { return nil }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        switch keys[0] {
        case "lineItem":
            guard value.allSatisfy(\.isASCII), value.allSatisfy(\.isNumber) else { return nil }
            items.append(ShopifySourceItem(key: .lineItem(value), quantity: number.intValue))
        case "sku": items.append(ShopifySourceItem(key: .sku(value), quantity: number.intValue))
        default: items.append(ShopifySourceItem(key: .name(value), quantity: number.intValue))
        }
    }
    return items
}

// MARK: Reading the Slant order

/// `metadata.sourceShop` as written (trimmed, lower case), or nil when the order has none.
func orderShopifySourceShop(_ order: [String: Any]) -> String? {
    guard let metadata = order["metadata"] as? [String: Any], let raw = metadata["sourceShop"] else { return nil }
    let text = ((raw as? String) ?? String(describing: raw)).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    // A value that isn't text still names *some* store: it's kept, so it can only ever fail the comparison.
    return text.isEmpty ? nil : text
}

func orderShopifySourceItems(_ order: [String: Any]) -> [ShopifySourceItem]? {
    shopifySourceItems(fromMetadata: (order["metadata"] as? [String: Any])?["sourceItems"])
}

/// The Slant order's shipping postcode, or empty.
func orderShippingPostcode(_ order: [String: Any]) -> String {
    let address = ((order["customer"] as? [String: Any])?["details"] as? [String: Any])?["address"] as? [String: Any]
    return ((address?["zip"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
}

// MARK: Same order?

/// A postcode for comparison: letters and digits only, upper case.
func shopifyComparablePostcode(_ text: String) -> String {
    String(text.uppercased().filter { ($0.isLetter || $0.isNumber) && $0.isASCII })
}

/// Postcodes match when equal once spaces and dashes are ignored; US ZIPs match on their first five digits, so
/// 02134 and 02134-1234 agree.
func shopifyPostcodesMatch(_ lhs: String, _ rhs: String) -> Bool {
    let a = shopifyComparablePostcode(lhs), b = shopifyComparablePostcode(rhs)
    guard !a.isEmpty, !b.isEmpty else { return false }
    if a == b { return true }
    let digitsOnly = a.allSatisfy(\.isNumber) && b.allSatisfy(\.isNumber)
    return digitsOnly && a.count >= 5 && b.count >= 5 && a.prefix(5) == b.prefix(5) && [5, 9].contains(a.count) && [5, 9].contains(b.count)
}

/// Names match ignoring case, accents and repeated spaces.
func shopifyNamesMatch(_ lhs: String, _ rhs: String) -> Bool {
    func comparable(_ text: String) -> String {
        shopifyCollapsedName(text).folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }
    let a = comparable(lhs), b = comparable(rhs)
    return !a.isEmpty && a == b
}

/// Why the Shopify order may not be the Slant order's (for an order imported without its store), or nil when the
/// recipient name and postcode both match.
func shopifyIdentityProblem(shopifyName: String, shopifyPostcode: String, slantName: String, slantPostcode: String) -> String? {
    let shopifyBlank = shopifyName.trimmingCharacters(in: .whitespaces).isEmpty || shopifyPostcode.trimmingCharacters(in: .whitespaces).isEmpty
    if shopifyBlank {
        return "Shopify didn’t share this order’s name and postcode, so Plinth can’t confirm it’s the order this draft was imported from. Add its tracking in Shopify."
    }
    if slantName.trimmingCharacters(in: .whitespaces).isEmpty || slantPostcode.trimmingCharacters(in: .whitespaces).isEmpty {
        return "This Slant order has no recipient name or postcode to compare, so Plinth can’t confirm it’s the same order. Add its tracking in Shopify."
    }
    let nameMatches = shopifyNamesMatch(shopifyName, slantName)
    let postcodeMatches = shopifyPostcodesMatch(shopifyPostcode, slantPostcode)
    switch (nameMatches, postcodeMatches) {
    case (true, true): return nil
    case (false, true): return "The Shopify order’s recipient name differs from this Slant order’s, so it may be another store’s order with the same name. Not sent."
    case (true, false): return "The Shopify order’s postcode differs from this Slant order’s, so it may be another store’s order with the same name. Not sent."
    case (false, false): return "The Shopify order’s recipient and postcode differ from this Slant order’s, so it may be another store’s order with the same name. Not sent."
    }
}

// MARK: Fulfilling only what Slant made

/// One fulfillment order line item and how many of its units to fulfil.
struct ShopifyFulfilmentLine: Equatable {
    let id: String
    let quantity: Int
}

/// A fulfillment order's line item as the check reads it.
struct ShopifyFulfilmentOrderLine: Equatable {
    let id: String
    let remaining: Int
    let lineItemID: String?
    let sku: String
    let name: String
}

/// The fulfillment order line items (and units) matching the draft's items, or the reason they can't be matched
/// exactly. Each item takes units from its matching lines in Shopify's order; an item without enough unfulfilled
/// units blocks the order rather than fulfilling something else.
func shopifyAllocateFulfilment(_ sourceItems: [ShopifySourceItem], lines: [ShopifyFulfilmentOrderLine]) -> Result<[ShopifyFulfilmentLine], StudioError> {
    var left = lines.map { max(0, $0.remaining) }
    var taken: [Int] = Array(repeating: 0, count: lines.count)
    for item in sourceItems {
        var needed = item.quantity
        for (index, line) in lines.enumerated() where needed > 0 && left[index] > 0 {
            let matches: Bool
            switch item.key {
            case .lineItem(let id): matches = line.lineItemID == id
            case .sku(let sku): matches = !normalizedSKU(line.sku).isEmpty && normalizedSKU(line.sku) == normalizedSKU(sku)
            case .name(let name): matches = shopifyCollapsedName(line.name).lowercased() == shopifyCollapsedName(name).lowercased()
            }
            guard matches else { continue }
            let units = min(needed, left[index])
            left[index] -= units
            taken[index] += units
            needed -= units
        }
        if needed > 0 {
            let label: String
            switch item.key {
            case .lineItem: label = "one of this draft’s items"
            case .sku(let sku): label = "SKU \(sku)"
            case .name(let name): label = "“\(name)”"
            }
            return .failure(StudioError("Shopify doesn’t show \(item.quantity) unfulfilled unit\(item.quantity == 1 ? "" : "s") of \(label) on this order, so Plinth can’t tell which items Slant made. Add its tracking in Shopify."))
        }
    }
    let result = lines.indices.filter { taken[$0] > 0 }.map { ShopifyFulfilmentLine(id: lines[$0].id, quantity: taken[$0]) }
    guard !result.isEmpty else {
        return .failure(StudioError("None of this draft’s items is waiting in Shopify. Add its tracking in Shopify."))
    }
    return .success(result)
}

// MARK: Plan limits

/// Shopify's Basic and Starter plans don't give custom apps customers' names and addresses.
func shopifyPlanLikelyWithholdsCustomerData(planName: String?, partnerDevelopment: Bool) -> Bool {
    guard !partnerDevelopment, let plan = planName?.lowercased() else { return false }
    return plan.contains("basic") || plan.contains("starter")
}

let shopifyCustomerDataPlanAdvice = "On Shopify’s Basic and Starter plans, apps don’t get customers’ names and addresses, so fetched orders can’t be drafted. Export the orders from Shopify admin (Orders › Export) and choose that CSV file in Import Orders instead."

/// The one sheet-level notice when most fetched orders came without a recipient or address, or nil.
func shopifyMissingCustomerDataNotice(_ orders: [OrderImportOrder]) -> String? {
    guard !orders.isEmpty else { return nil }
    let missing = orders.filter { $0.name.isEmpty || $0.line1.isEmpty }.count
    guard missing * 2 > orders.count else { return nil }
    let count = missing == orders.count ? "None of these orders came" : "\(missing) of these \(orders.count) orders came"
    return "\(count) with a name and address from Shopify. \(shopifyCustomerDataPlanAdvice)"
}
