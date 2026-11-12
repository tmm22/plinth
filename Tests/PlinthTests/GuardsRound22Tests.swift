import XCTest
@testable import Plinth

/// Round 22: Pay Several Drafts' duplicate check across CSV and fetched Shopify drafts, Look for Draft's pacing and
/// count, reference fields Slant would merge, and two catalogue captions.
final class GuardsRound22Tests: XCTestCase {
    // MARK: Pay Several Drafts: one Shopify sale drafted from a CSV and by Fetch from Shopify

    private func order(_ status: String, source: String? = "shopify", id: String = "#1001", shop: String? = nil,
                       items: String? = nil) -> [String: Any] {
        var metadata: [String: Any] = ["sourceOrderId": id]
        if let source { metadata["source"] = source }
        if let shop { metadata["sourceShop"] = shop }
        if let items { metadata["sourceItems"] = items }
        return ["status": status, "metadata": metadata]
    }

    private func record(_ id: String, _ order: [String: Any]) -> Record {
        var values = order
        values["publicId"] = id
        return Record(values: values)
    }

    private let csvItems = "[{\"quantity\":1,\"sku\":\"MUG-1\"}]"
    private let fetchedItems = "[{\"lineItem\":\"111\",\"quantity\":1}]"

    private func csvDraft(_ status: String = "DRAFT") -> [String: Any] { order(status, items: csvItems) }
    private func fetchedDraft(_ status: String = "DRAFT", shop: String = "a.myshopify.com") -> [String: Any] {
        order(status, shop: shop, items: fetchedItems)
    }

    func testAPlacedCSVOrderHoldsTheSaleAgainstAFetchedDraft() {
        let placed = batchPayPlacedMarketplaceKeys([record("P1", csvDraft("SUBMITTED"))])
        XCTAssertEqual(placed.count, 1)
        let reasons = batchPayDuplicateExclusions([(id: "F", order: fetchedDraft())], placedKeys: placed)
        XCTAssertTrue(reasons["F"]?.contains("already placed") == true, "\(reasons)")
        // And the other way round: a placed fetched order holds the sale against a CSV draft.
        let placedFetched = batchPayPlacedMarketplaceKeys([record("P2", fetchedDraft("PRINTING"))])
        XCTAssertNotNil(batchPayDuplicateExclusions([(id: "C", order: csvDraft())], placedKeys: placedFetched)["C"])
    }

    func testACSVDraftAndAFetchedDraftInOneReviewPayOnlyTheFirst() {
        let reasons = batchPayDuplicateExclusions([(id: "C", order: csvDraft()), (id: "F", order: fetchedDraft())], placedKeys: [])
        XCTAssertEqual(Set(reasons.keys), ["F"])
        XCTAssertTrue(reasons["F"]?.contains("Only the first is included") == true)
        let reversed = batchPayDuplicateExclusions([(id: "F", order: fetchedDraft()), (id: "C", order: csvDraft())], placedKeys: [])
        XCTAssertEqual(Set(reversed.keys), ["C"])
    }

    func testALeftOutOrHiddenCSVDraftHoldsTheSale() {
        let leftOut = batchPayDuplicateExclusions([(id: "F", order: fetchedDraft()), (id: "C", order: csvDraft())],
                                                  placedKeys: [], excludedIDs: ["C"])
        XCTAssertTrue(leftOut["F"]?.contains("was left out") == true, "\(leftOut)")
        XCTAssertNil(leftOut["C"], "a draft left out for another reason gets no second reason")
        let hidden = batchPayHiddenDraftMarketplaceKeys([record("H", csvDraft())],
                                                        hidden: ["H"], reviewedIDs: ["F"])
        XCTAssertTrue(batchPayDuplicateExclusions([(id: "F", order: fetchedDraft())], placedKeys: [], hiddenKeys: hidden)["F"]?
            .contains("hid") == true)
    }

    func testEveryEarlierDraftCountsEvenOneLeftOutByThisCheck() {
        // The match isn't transitive: both stores' drafts match the CSV draft, though not each other, so both are left
        // out, the second because of the first draft in the review.
        let reasons = batchPayDuplicateExclusions([
            (id: "C", order: csvDraft()),
            (id: "A", order: fetchedDraft(shop: "a.myshopify.com")),
            (id: "B", order: fetchedDraft(shop: "b.myshopify.com"))
        ], placedKeys: [])
        XCTAssertEqual(Set(reasons.keys), ["A", "B"])
        // A draft left out because its sale was placed still holds it against later drafts: C matches the placed
        // store-a order, and B (store b) matches only C.
        let placed = batchPayPlacedMarketplaceKeys([record("P", fetchedDraft("SUBMITTED", shop: "a.myshopify.com"))])
        let chained = batchPayDuplicateExclusions([
            (id: "A", order: fetchedDraft(shop: "a.myshopify.com")),
            (id: "C", order: csvDraft()),
            (id: "B", order: fetchedDraft(shop: "b.myshopify.com"))
        ], placedKeys: placed)
        XCTAssertTrue(chained["A"]?.contains("already placed") == true)
        XCTAssertTrue(chained["C"]?.contains("already placed") == true)
        XCTAssertTrue(chained["B"]?.contains("Only the first") == true, "\(chained)")
    }

    func testDifferentMarketplacesStoresAndSplitsStayApart() {
        func match(_ a: [String: Any], _ b: [String: Any]) -> Bool {
            batchPayMarketplaceKeysMatch(batchPayMarketplaceKey(a)!, batchPayMarketplaceKey(b)!)
        }
        XCTAssertFalse(match(order("DRAFT", source: "etsy", id: "3141"), order("DRAFT", source: "shopify", id: "3141")))
        XCTAssertFalse(match(order("DRAFT", id: "#1001"), order("DRAFT", id: "#1002")))
        XCTAssertFalse(match(fetchedDraft(shop: "a.myshopify.com"), fetchedDraft(shop: "b.myshopify.com")))
        // Both by line item, or both by SKU, and different: a deliberate split.
        XCTAssertFalse(match(order("DRAFT", shop: "a.myshopify.com", items: fetchedItems),
                             order("DRAFT", shop: "a.myshopify.com", items: "[{\"lineItem\":\"222\",\"quantity\":1}]")))
        XCTAssertFalse(match(order("DRAFT", items: csvItems), order("DRAFT", items: "[{\"quantity\":1,\"sku\":\"MUG-2\"}]")))
        XCTAssertFalse(match(order("DRAFT", items: csvItems), order("DRAFT", items: "[{\"name\":\"Mug\",\"quantity\":1}]")),
                       "SKU and name are both a CSV's way of recording items")
        // The existing split rule, through the batch.
        XCTAssertEqual(Set(batchPayDuplicateExclusions([
            (id: "A", order: order("DRAFT", shop: "a.myshopify.com", items: fetchedItems)),
            (id: "B", order: order("DRAFT", shop: "a.myshopify.com", items: "[{\"lineItem\":\"222\",\"quantity\":1}]"))
        ], placedKeys: []).keys), [])
    }

    func testWhatCantTellTwoSalesApartMatches() {
        func match(_ a: [String: Any], _ b: [String: Any]) -> Bool {
            batchPayMarketplaceKeysMatch(batchPayMarketplaceKey(a)!, batchPayMarketplaceKey(b)!)
        }
        XCTAssertTrue(match(order("DRAFT", source: nil), order("DRAFT", source: "shopify")), "a missing source matches")
        XCTAssertTrue(match(order("DRAFT", source: " Shopify "), order("DRAFT", source: "shopify")))
        XCTAssertTrue(match(order("DRAFT", source: "etsy", id: "ab12"), order("DRAFT", source: "etsy", id: "AB12")), "IDs in any case")
        XCTAssertTrue(match(order("DRAFT"), fetchedDraft()), "missing items and store")
        XCTAssertTrue(match(order("DRAFT", items: "not json"), fetchedDraft()), "unreadable items")
        XCTAssertTrue(match(order("DRAFT", items: "not json"), order("DRAFT", items: csvItems)), "unreadable items, same kind")
        XCTAssertTrue(match(order("DRAFT", shop: "a.myshopify.com", items: "[{\"lineItem\":\"1\",\"quantity\":1},{\"quantity\":1,\"sku\":\"X\"}]"),
                            order("DRAFT", shop: "a.myshopify.com", items: "[{\"lineItem\":\"2\",\"quantity\":1}]")),
                      "a list that mixes line items and SKUs can't be told apart")
        XCTAssertTrue(match(order("DRAFT", items: "[{\"quantity\":1,\"sku\":\"MUG-1\"}]"),
                            order("DRAFT", items: "[{\"sku\":\"MUG-1\",\"quantity\":1}]")), "the same items written another way")
    }

    func testEveryPairWithEqualKeysStillMatches() {
        // ("a|b", "c") and ("a", "b|c") shared a key before round 22.
        let sources: [String?] = [nil, "shopify", "Etsy", "a", "a|b"]
        let ids = ["#1001", "c", "b|c", "x\\y"]
        let shops: [String?] = [nil, "a.myshopify.com", "B.myshopify.com|"]
        let items: [String?] = [nil, "[{\"lineItem\":\"1\",\"quantity\":1}]", "[{\"quantity\":1,\"sku\":\"MUG-1\"}]",
                                "garbage|x"]
        var orders: [[String: Any]] = []
        for source in sources { for id in ids { for shop in shops { for item in items {
            orders.append(order("DRAFT", source: source, id: id, shop: shop, items: item))
        } } } }
        let keys = orders.map { batchPayMarketplaceKey($0)! }
        // The key before round 22: the parts joined without escaping.
        let oldKeys = orders.map { BatchPayMarketplaceRef(order: $0)!.unescapedKey }
        var pairs = 0
        for a in orders.indices {
            XCTAssertEqual(BatchPayMarketplaceRef(key: keys[a]), BatchPayMarketplaceRef(order: orders[a]), "the key reads back exactly")
            for b in orders.indices where oldKeys[a] == oldKeys[b] || keys[a] == keys[b] {
                pairs += 1
                XCTAssertTrue(batchPayMarketplaceKeysMatch(keys[a], keys[b]), "\(keys[a]) vs \(keys[b])")
            }
        }
        XCTAssertGreaterThan(pairs, orders.count, "some different orders shared a key before round 22")
        // The keys of orders without a separator or backslash are unchanged.
        XCTAssertEqual(batchPayMarketplaceKey(order("DRAFT", source: "etsy", id: "2718")), "etsy|2718||")
        XCTAssertEqual(batchPayMarketplaceKey(order("DRAFT", source: "a|b", id: "c")), "a\\|b|c||")
        XCTAssertNil(BatchPayMarketplaceRef(key: "a|b"))
        XCTAssertNil(BatchPayMarketplaceRef(key: "a|b|c\\"))
        XCTAssertFalse(batchPayMarketplaceKeysMatch("a|b", "a|B"), "keys that can't be read match only themselves")
        XCTAssertTrue(batchPayMarketplaceKeysMatch("a|b", "a|b"))
    }

    func testTheReviewNoticeMatchesTheSameWay() {
        let placedCSV = record("P1", csvDraft("SUBMITTED"))
        XCTAssertEqual(orderReviewMarketplaceDuplicateNotice(fetchedDraft(), orderID: "D1", loaded: [placedCSV]),
                       "Possible duplicate: Shopify order #1001 already has a placed order.")
        let otherCSVDraft = record("D2", csvDraft())
        XCTAssertEqual(orderReviewMarketplaceDuplicateNotice(fetchedDraft(), orderID: "D1", loaded: [otherCSVDraft]),
                       "Possible duplicate: another draft is also for Shopify order #1001.")
        let otherStore = record("D3", fetchedDraft(shop: "b.myshopify.com"))
        XCTAssertNil(orderReviewMarketplaceDuplicateNotice(fetchedDraft(), orderID: "D1", loaded: [otherStore]))
    }

    // MARK: Look for Draft on Slant

    private func page(_ ids: [String]) -> [Record] { ids.map { Record(values: ["publicId": $0]) } }

    func testOrdersReadAreCountedOnce() {
        let hundred = page((1...100).map { "SLANT_\($0)" })
        XCTAssertEqual(draftMarkerDistinctOrderCount([hundred, hundred]), 100, "Slant's platform filter can't be relied on")
        XCTAssertEqual(draftMarkerDistinctOrderCount([hundred, page(["SLANT_1", "SLANT_200"])]), 101)
        XCTAssertEqual(draftMarkerDistinctOrderCount([[Record(values: [:]), Record(values: [:])], page(["A"])]), 3,
                       "a row without an ID counts as its own order")
        XCTAssertEqual(draftMarkerDistinctOrderCount([]), 0)
        var result = DraftMarkerSearchResult()
        result.ordersRead = draftMarkerDistinctOrderCount([hundred, hundred])
        XCTAssertEqual(draftCheckNotFoundText(plural: false, result: result), "Slant has no matching draft among your 100 newest orders.")
    }

    func testRequestsArePacedAndStopWhenTheAllowanceRunsLow() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let low = RateLimitInfo(limit: 100, remaining: 10, reset: now.addingTimeInterval(30))
        let lowButReset = RateLimitInfo(limit: 100, remaining: 10, reset: now.addingTimeInterval(-1))
        let enough = RateLimitInfo(limit: 100, remaining: 11, reset: now.addingTimeInterval(30))
        XCTAssertEqual(draftMarkerCheckBeforeRequest(lastStart: nil, rateLimit: low, now: now), .send(wait: 0),
                       "the seller's press sends its first request")
        guard case .send(let wait) = draftMarkerCheckBeforeRequest(lastStart: now.addingTimeInterval(-0.2), rateLimit: enough, now: now) else {
            return XCTFail("a later page is sent while requests remain")
        }
        XCTAssertEqual(wait, 0.4, accuracy: 0.0001)
        XCTAssertEqual(draftMarkerCheckBeforeRequest(lastStart: now, rateLimit: nil, now: now), .send(wait: comparisonMinimumSpacing))
        XCTAssertEqual(draftMarkerCheckBeforeRequest(lastStart: now.addingTimeInterval(-5), rateLimit: enough, now: now), .send(wait: 0))
        XCTAssertEqual(draftMarkerCheckBeforeRequest(lastStart: now.addingTimeInterval(-5), rateLimit: low, now: now), .stop)
        XCTAssertEqual(draftMarkerCheckBeforeRequest(lastStart: now.addingTimeInterval(-5), rateLimit: lowButReset, now: now), .send(wait: 0))
    }

    // MARK: Reference fields Slant would store as one

    func testReferenceFieldsThatSlantWouldMergeAreRefused() throws {
        XCTAssertEqual(orderMetadataKeyFolded("order_ID"), "orderid")
        XCTAssertThrowsError(try orderMetadataDictionary([OrderMetadataField(key: "order_id", value: "1"),
                                                          OrderMetadataField(key: "orderId", value: "2")])) { error in
            XCTAssertEqual((error as? StudioError)?.message, "“order_id” and “orderId” are the same field on Slant. Rename one.")
        }
        XCTAssertThrowsError(try orderMetadataDictionary([OrderMetadataField(key: "Batch", value: "1"),
                                                          OrderMetadataField(key: " batch ", value: "2")]))
        XCTAssertThrowsError(try orderMetadataDictionary([OrderMetadataField(key: "a", value: "1"),
                                                          OrderMetadataField(key: "a", value: "2")])) { error in
            XCTAssertEqual((error as? StudioError)?.message, "Each reference field needs a different name.")
        }
        let fine = try orderMetadataDictionary([OrderMetadataField(key: "a", value: "1"), OrderMetadataField(key: "b", value: "2")])
        XCTAssertEqual(fine as? [String: String], ["a": "1", "b": "2"])
        // Plinth's own fields are unchanged: the marker and reprintOf still give way to the seller's spelling.
        XCTAssertTrue(orderMetadataHasKey(["studio_draft_id": "mine"], studioDraftMarkerKey))
        XCTAssertNil(orderMetadataAddingReprintOf(["reprint_of": "x"], original: "SLANT_1")["reprintOf"])
        XCTAssertTrue(orderReferenceFieldsCaption.hasSuffix("Don’t put passwords or keys here."))
    }

    // MARK: Catalogue captions

    func testSlantsStandInGreyIsNamedInTheListingFooter() {
        XCTAssertTrue(slantFallbackSwatch("#a1a1a1"))
        XCTAssertTrue(slantFallbackSwatch(" #A1A1A1 \n"))
        XCTAssertFalse(slantFallbackSwatch("#a1a1a2"))
        XCTAssertFalse(slantFallbackSwatch("a1a1a1"))
        XCTAssertFalse(slantFallbackSwatch(""))
        XCTAssertEqual(listingColourFooter(materialChosen: true, hexValue: "#A1A1A1", filamentsLoaded: true),
                       "Slant shows this grey when it has no colour on file for a material, so the print may be a different colour.")
        XCTAssertEqual(listingColourFooter(materialChosen: true, hexValue: "#f91010", filamentsLoaded: true),
                       "The colour is Slant’s swatch for the material, so it may differ a little from the printed filament.")
        XCTAssertEqual(listingColourFooter(materialChosen: true, hexValue: "not a colour", filamentsLoaded: true),
                       "Slant gave no colour for this material, so neutral grey is used.")
        XCTAssertEqual(listingColourFooter(materialChosen: true, hexValue: nil, filamentsLoaded: true),
                       "Slant gave no colour for this material, so neutral grey is used.")
        XCTAssertEqual(listingColourFooter(materialChosen: false, hexValue: nil, filamentsLoaded: false),
                       "Materials load from your Slant account; until then the model is shown in neutral grey.")
        XCTAssertEqual(listingColourFooter(materialChosen: false, hexValue: nil, filamentsLoaded: true),
                       "The colour is Slant’s swatch for the material, so it may differ a little from the printed filament.")
        // The grey is still Slant's colour to render: the caption changes, the colour doesn't.
        XCTAssertNotNil(listingColour(hex: "#a1a1a1"))
    }

    func testStationeryWithANullPriceSaysWhatSlantsDocsSay() {
        let card = Record(values: ["id": "card", "price": NSNull()])
        XCTAssertNil(try? productCostCatalogPrice(card, stationery: true).get(), "never counted as free")
        guard case .failure(let reason) = productCostCatalogPrice(card, stationery: true) else { return XCTFail() }
        XCTAssertEqual(reason.message, productCostStationeryNoPriceText)
        XCTAssertTrue(productCostStationeryNoPriceText.contains("free of charge"))
        func message(_ result: Result<Decimal, StudioError>) -> String? {
            if case .failure(let error) = result { return error.message }
            return nil
        }
        XCTAssertEqual(message(productCostCatalogPrice(card)), "Slant lists no price for it.", "a component with a null price")
        XCTAssertEqual(message(productCostCatalogPrice(Record(values: ["id": "card"]), stationery: true)), "Slant lists no price for it.",
                       "a missing price isn't Slant's documented null")
        XCTAssertEqual(message(productCostCatalogPrice(Record(values: ["price": "free"]), stationery: true)), "Slant lists no price for it.")
        XCTAssertEqual(try? productCostCatalogPrice(Record(values: ["price": 0]), stationery: true).get(), Decimal(0))
    }
}
