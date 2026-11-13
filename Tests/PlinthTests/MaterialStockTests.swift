import XCTest
@testable import Plinth

final class MaterialStockTests: XCTestCase {
    let pla = Record(values: ["id": "pla-black", "name": "PLA Black", "profile": "PLA", "available": true])
    let petgOut = Record(values: ["id": "petg-red", "name": "PETG Red", "profile": "PETG", "available": false])
    let silkOut = Record(values: ["id": "silk-gold", "name": "Silk Gold", "profile": "PLA", "available": false])
    /// No availability flag: unknown, never "out of stock".
    let unknown = Record(values: ["id": "pla-white", "name": "PLA White", "profile": "PLA"])

    func product(_ name: String, materials: [String], lineNames: [String]? = nil, id: UUID = UUID()) -> SavedProduct {
        let lines = materials.enumerated().map { index, material in
            SavedProductLine(type: "PRINT", reference: "file-\(index)", filamentID: material, name: lineNames?[index] ?? "")
        }
        return SavedProduct(id: id, name: name, sku: "", lines: lines)
    }

    // MARK: Which products

    func testMaterialsNotLoadedIsNotCheckedNeverAllWellNorOutOfStock() {
        let products = [product("Keyring", materials: ["petg-red"])]
        XCTAssertEqual(savedProductStockCheck(products: products, filaments: []), .notChecked)
        XCTAssertTrue(savedProductStockCheck(products: products, filaments: []).issues.isEmpty)
        XCTAssertNil(savedProductStockNoticeHeadline([]))
    }

    func testOutOfStockAndGoneMaterialsUseTheResolversWords() {
        let keyring = product("Keyring", materials: ["petg-red"])
        let stand = product("Stand", materials: ["retired-id"], lineNames: ["Base"])
        let fine = product("Bracket", materials: ["pla-black", "pla-white"])
        let issues = savedProductStockCheck(products: [stand, keyring, fine], filaments: [pla, petgOut, unknown]).issues
        XCTAssertEqual(issues.map(\.productName), ["Keyring", "Stand"], "sorted by name; a fine product is left out")
        XCTAssertEqual(issues[0].problems.map(\.reason), ["PETG Red is out of stock."])
        XCTAssertEqual(issues[0].problems.first?.kind, .outOfStock)
        XCTAssertEqual(issues[1].problems.map(\.reason), ["The material for “Base” is no longer offered."])
        XCTAssertEqual(issues[1].problems.first?.kind, .noLongerOffered)
        XCTAssertNil(issues[1].problems.first?.materialName)

        // The same reasons the Saved Products list gives (`savedProductOrderability`).
        let listed = savedProductOrderability(keyring, localModels: [], filaments: [pla, petgOut], components: [], stationery: [])
        XCTAssertEqual(listed.blockers, ["PETG Red is out of stock."])
    }

    func testAProductNeedingTwoMaterialsListsEachOnce() throws {
        let two = product("Two-tone", materials: ["petg-red", "silk-gold", " petg-red "])
        let issue = try XCTUnwrap(savedProductStockCheck(products: [two], filaments: [pla, petgOut, silkOut]).issues.first)
        XCTAssertEqual(issue.problems.map(\.materialID), ["petg-red", "silk-gold"])
        XCTAssertEqual(savedProductStockNoticeHeadline([issue]),
                       "Saved product “Two-tone” can’t be ordered: PETG Red is out of stock. (+1 more)")
        // Only one of the two out: still affected.
        let one = savedProductStockCheck(products: [two], filaments: [pla, petgOut,
                                                                      Record(values: ["id": "silk-gold", "name": "Silk Gold", "available": true])])
        XCTAssertEqual(one.issues.first?.problems.map(\.materialID), ["petg-red"])
    }

    func testEmptyMaterialIDsAndOtherItemTypesAreIgnored() {
        var withBox = product("Gift", materials: ["", "  "])
        withBox.lines.append(SavedProductLine(type: "COMPONENT", reference: "box-1", filamentID: "petg-red"))
        XCTAssertEqual(savedProductStockCheck(products: [withBox], filaments: [petgOut]), .checked([]))
        XCTAssertFalse(savedProductsNeedMaterials([withBox]))
        XCTAssertTrue(savedProductsNeedMaterials([product("A", materials: ["pla-black"])]))
    }

    func testAnUnreadableProductsFileShowsNothing() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("MaterialStockTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent(savedProductsFileName)
        try Data("not json".utf8).write(to: url)
        let products = loadSavedProducts(from: url)
        XCTAssertEqual(savedProductStockCheck(products: products, filaments: [petgOut]), .checked([]))
        XCTAssertNil(savedProductStockNoticeHeadline(savedProductStockCheck(products: products, filaments: [petgOut]).issues))
    }

    func testHundredsOfProducts() {
        let products = (0..<400).map { product(String(format: "Product %03d", $0), materials: [$0.isMultiple(of: 2) ? "petg-red" : "pla-black"]) }
        let issues = savedProductStockCheck(products: products, filaments: [pla, petgOut]).issues
        XCTAssertEqual(issues.count, 200)
        XCTAssertEqual(savedProductStockNoticeHeadline(issues),
                       "200 saved products can’t be ordered because a material is out of stock or no longer offered, including “Product 000”, “Product 002” and “Product 004”.")
        XCTAssertEqual(savedProductStockPairs(issues).count, 200)
    }

    // MARK: Text

    func testNoticeTextForOneSeveralAndMany() {
        let a = product("Alpha", materials: ["petg-red"]), b = product("Beta", materials: ["gone"]), c = product("Gamma", materials: ["silk-gold"])
        let d = product("Delta", materials: ["gone-2"])
        let filaments = [pla, petgOut, silkOut]
        let one = savedProductStockCheck(products: [a], filaments: filaments).issues
        XCTAssertEqual(savedProductStockNoticeHeadline(one), "Saved product “Alpha” can’t be ordered: PETG Red is out of stock.")
        XCTAssertNil(savedProductStockNoticeMaterialsLine(one))

        let three = savedProductStockCheck(products: [c, b, a], filaments: filaments).issues
        XCTAssertEqual(savedProductStockNoticeHeadline(three),
                       "3 saved products can’t be ordered because a material is out of stock or no longer offered: “Alpha”, “Beta” and “Gamma”.")
        XCTAssertEqual(savedProductStockNoticeMaterialsLine(three), "Out of stock: PETG Red and Silk Gold. 1 material is no longer offered.")

        let four = savedProductStockCheck(products: [a, b, c, d], filaments: filaments).issues
        XCTAssertEqual(savedProductStockNoticeHeadline(four),
                       "4 saved products can’t be ordered because a material is out of stock or no longer offered, including “Alpha”, “Beta” and “Delta”.")
        XCTAssertEqual(savedProductStockNoticeMaterialsLine(four), "Out of stock: PETG Red and Silk Gold. 2 materials are no longer offered.")
    }

    func testManyOutOfStockMaterialsAreCounted() {
        let records = (0..<6).map { Record(values: ["id": "m\($0)", "name": "Colour \($0)", "available": false]) }
        let products = (0..<6).map { product("P\($0)", materials: ["m\($0)"]) }
        let issues = savedProductStockCheck(products: products, filaments: records).issues
        XCTAssertEqual(savedProductStockNoticeMaterialsLine(issues), "Out of stock: Colour 0, Colour 1, Colour 2, Colour 3 and 2 others.")
    }

    func testLongNamesAreShortened() throws {
        let long = String(repeating: "x", count: 200)
        let issues = savedProductStockCheck(products: [product(long, materials: ["petg-red"])], filaments: [petgOut]).issues
        let headline = try XCTUnwrap(savedProductStockNoticeHeadline(issues))
        XCTAssertTrue(headline.contains("“" + String(repeating: "x", count: savedProductStockNameLimit - 1) + "…”"))
        XCTAssertLessThanOrEqual(headline.count, 130)
    }

    func testAdviceNamesWhenTheMaterialsWereRead() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertEqual(savedProductStockNoticeAdvice(count: 1, materialsAt: nil),
                       "To order this product from Slant, choose another material in Saved Products.")
        XCTAssertTrue(savedProductStockNoticeAdvice(count: 2, materialsAt: now, now: now, calendar: calendar).contains("these products"))
        XCTAssertTrue(savedProductStockNoticeAdvice(count: 2, materialsAt: now, now: now, calendar: calendar).contains("Slant’s materials were read today at"))
        XCTAssertFalse(savedProductStockNoticeAdvice(count: 2, materialsAt: now.addingTimeInterval(-3 * 86_400), now: now, calendar: calendar)
            .contains("today"))
    }

    // MARK: Dismissal

    func testDismissalLifecycle() {
        let keyringID = UUID(), standID = UUID()
        let keyring = product("Keyring", materials: ["petg-red"], id: keyringID)
        let stand = product("Stand", materials: ["silk-gold"], id: standID)
        let out = savedProductStockCheck(products: [keyring], filaments: [pla, petgOut, silkOut])
        let current = savedProductStockPairs(out.issues)
        XCTAssertEqual(current, ["\(keyringID.uuidString)|petg-red"])
        XCTAssertTrue(savedProductStockNoticeVisible(current: current, dismissed: []))

        // Dismissed: hidden for the same set, including after a relaunch, before and after materials load.
        var dismissed = current
        XCTAssertFalse(savedProductStockNoticeVisible(current: current, dismissed: dismissed))
        let saved = encodeSavedProductStockDismissal(dismissed)
        dismissed = decodeSavedProductStockDismissal(saved)
        XCTAssertEqual(savedProductStockDismissalAfterCheck(.notChecked, dismissed: dismissed), dismissed, "materials not loaded yet")
        dismissed = savedProductStockDismissalAfterCheck(out, dismissed: dismissed)
        XCTAssertFalse(savedProductStockNoticeVisible(current: current, dismissed: dismissed))

        // A changed set (another product now affected) shows again.
        let wider = savedProductStockCheck(products: [keyring, stand], filaments: [pla, petgOut, silkOut])
        XCTAssertTrue(savedProductStockNoticeVisible(current: savedProductStockPairs(wider.issues), dismissed: dismissed))

        // A smaller set stays hidden, and the dismissal narrows to it.
        let narrowed = savedProductStockDismissalAfterCheck(wider, dismissed: savedProductStockPairs(wider.issues))
        let onlyStand = savedProductStockCheck(products: [keyring, stand],
                                               filaments: [pla, silkOut, Record(values: ["id": "petg-red", "name": "PETG Red", "available": true])])
        XCTAssertFalse(savedProductStockNoticeVisible(current: savedProductStockPairs(onlyStand.issues), dismissed: narrowed))
        let afterNarrowing = savedProductStockDismissalAfterCheck(onlyStand, dismissed: narrowed)
        XCTAssertEqual(afterNarrowing, ["\(standID.uuidString)|silk-gold"])
        // ... so the keyring's material running out again is new.
        XCTAssertTrue(savedProductStockNoticeVisible(current: savedProductStockPairs(wider.issues), dismissed: afterNarrowing))

        // Back in stock: the notice goes and the dismissal is forgotten.
        let inStock = savedProductStockCheck(products: [keyring, stand], filaments: [pla,
            Record(values: ["id": "petg-red", "name": "PETG Red", "available": true]),
            Record(values: ["id": "silk-gold", "name": "Silk Gold", "available": true])])
        XCTAssertEqual(inStock, .checked([]))
        XCTAssertEqual(savedProductStockDismissalAfterCheck(inStock, dismissed: afterNarrowing), [])
        XCTAssertNil(encodeSavedProductStockDismissal([]), "nothing dismissed removes the preference")
    }

    func testMaterialGoneAfterOutOfStockKeepsTheDismissal() {
        let id = UUID()
        let keyring = product("Keyring", materials: ["petg-red"], id: id)
        let outOfStock = savedProductStockPairs(savedProductStockCheck(products: [keyring], filaments: [petgOut]).issues)
        let gone = savedProductStockPairs(savedProductStockCheck(products: [keyring], filaments: [pla]).issues)
        XCTAssertEqual(outOfStock, gone, "only IDs are compared, so the same product and material stays dismissed")
    }

    func testSavedDismissalIsReadLenientlyAndHoldsOnlyIDs() {
        let id = UUID()
        let decoded = decodeSavedProductStockDismissal(["\(id.uuidString)|pla-black", "not-a-uuid|x", "\(id.uuidString)|", 7,
                                                        "\(id.uuidString)|bad\nline", String(repeating: "a", count: 400)] as [Any])
        XCTAssertEqual(decoded, ["\(id.uuidString)|pla-black"])
        XCTAssertEqual(decodeSavedProductStockDismissal("nonsense"), [])
        XCTAssertEqual(decodeSavedProductStockDismissal(nil), [])
        let many = Set((0...savedProductStockDismissedMaxEntries).map { "\(UUID().uuidString)|m\($0)" })
        XCTAssertNil(encodeSavedProductStockDismissal(many), "too many to save: kept for the session only")
        XCTAssertEqual(encodeSavedProductStockDismissal(["\(id.uuidString)|b", "\(id.uuidString)|a"]),
                       ["\(id.uuidString)|a", "\(id.uuidString)|b"])
    }

    func testDismissalRoundTripsThroughATestDefaultsSuite() throws {
        let name = testDefaultsSuiteName("MaterialStockTests")
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { removeTestDefaultsSuite(defaults, named: name) }
        let pairs: Set<String> = ["\(UUID().uuidString)|petg-red"]
        defaults.set(encodeSavedProductStockDismissal(pairs), forKey: savedProductStockDismissedDefaultsKey)
        XCTAssertEqual(decodeSavedProductStockDismissal(defaults.array(forKey: savedProductStockDismissedDefaultsKey)), pairs)
    }

    // MARK: Screens and source

    func testNoticeOnlyWithSlantAndOnSellerScreens() {
        XCTAssertTrue(savedProductStockNoticeScreen(destination: .models, service: .slant))
        XCTAssertTrue(savedProductStockNoticeScreen(destination: .orders, service: .slant))
        XCTAssertTrue(savedProductStockNoticeScreen(destination: .catalog, service: .slant))
        XCTAssertFalse(savedProductStockNoticeScreen(destination: .api, service: .slant))
        XCTAssertFalse(savedProductStockNoticeScreen(destination: .activity, service: .slant))
        XCTAssertFalse(savedProductStockNoticeScreen(destination: .models, service: .dapi))
        XCTAssertFalse(savedProductStockNoticeScreen(destination: .orders, service: .dapi))
    }

    func testTheNewerMaterialsWin() {
        let early = Date(timeIntervalSince1970: 1_000), late = Date(timeIntervalSince1970: 2_000)
        XCTAssertEqual(materialStockSource(storeLoadedAt: early, storeHasMaterials: true, snapshotAt: nil), .store)
        XCTAssertEqual(materialStockSource(storeLoadedAt: early, storeHasMaterials: true, snapshotAt: late), .snapshot)
        XCTAssertEqual(materialStockSource(storeLoadedAt: late, storeHasMaterials: true, snapshotAt: early), .store)
        XCTAssertEqual(materialStockSource(storeLoadedAt: nil, storeHasMaterials: false, snapshotAt: early), .snapshot)
        XCTAssertEqual(materialStockSource(storeLoadedAt: late, storeHasMaterials: false, snapshotAt: early), .snapshot)
    }

    // MARK: The daily read's schedule

    func conditions(_ change: (inout MaterialStockWatchConditions) -> Void = { _ in }) -> MaterialStockWatchConditions {
        let now = Date(timeIntervalSince1970: 10_000_000)
        var c = MaterialStockWatchConditions(launchedAt: now.addingTimeInterval(-3_600), lastAttemptAt: nil,
                                             newestMaterialsAt: now.addingTimeInterval(-25 * 3_600), now: now)
        change(&c)
        return c
    }

    func testTheReadRunsOnlyWhenDue() {
        XCTAssertNil(materialStockWatchSkipReason(conditions()))
        XCTAssertEqual(materialStockWatchSkipReason(conditions { $0.hasKey = false }), .noKey)
        XCTAssertEqual(materialStockWatchSkipReason(conditions { $0.slantIsPrintService = false }), .otherService)
        XCTAssertEqual(materialStockWatchSkipReason(conditions { $0.productsNeedMaterials = false }), .nothingToCheck)
        XCTAssertEqual(materialStockWatchSkipReason(conditions { $0.launchedAt = $0.now.addingTimeInterval(-59) }), .tooSoonAfterLaunch)
        XCTAssertNil(materialStockWatchSkipReason(conditions { $0.launchedAt = $0.now.addingTimeInterval(-60) }))
        // Once a day: after any attempt (a failure included, so nothing is retried before then) ...
        XCTAssertEqual(materialStockWatchSkipReason(conditions { $0.lastAttemptAt = $0.now.addingTimeInterval(-23 * 3_600) }), .notDue)
        XCTAssertNil(materialStockWatchSkipReason(conditions { $0.lastAttemptAt = $0.now.addingTimeInterval(-24 * 3_600) }))
        // ... and never while Plinth already holds materials from the last day (launch, Refresh, Models, composers).
        XCTAssertEqual(materialStockWatchSkipReason(conditions { $0.newestMaterialsAt = $0.now.addingTimeInterval(-3_600) }), .notDue)
        XCTAssertNil(materialStockWatchSkipReason(conditions { $0.newestMaterialsAt = nil }))
    }

    func testTheReadFollowsTheOrderWatchRules() {
        XCTAssertEqual(materialStockWatchSkipReason(conditions { $0.busy = true }), .order(.busy))
        XCTAssertEqual(materialStockWatchSkipReason(conditions { $0.modalUIShown = true }), .order(.modalUI))
        XCTAssertEqual(materialStockWatchSkipReason(conditions { $0.inFlight = true }), .order(.inFlight))
        XCTAssertEqual(materialStockWatchSkipReason(conditions { $0.accountPaused = true }), .order(.accountPaused))
        let now = conditions().now
        let until = now.addingTimeInterval(120)
        XCTAssertEqual(materialStockWatchSkipReason(conditions { $0.backoffUntil = until }), .order(.rateLimited(until: until)))
        let low = RateLimitInfo(limit: 100, remaining: orderWatchRateLimitReserve, reset: now.addingTimeInterval(30))
        XCTAssertEqual(materialStockWatchSkipReason(conditions { $0.rateLimit = low }), .order(.rateLimited(until: low.reset)))
        XCTAssertNil(materialStockWatchSkipReason(conditions { $0.rateLimit = RateLimitInfo(limit: 100, remaining: 80, reset: now.addingTimeInterval(30)) }))
        XCTAssertEqual(materialStockWatchNextDelay(after: .order(.rateLimited(until: now.addingTimeInterval(30))), now: now), 32)
        XCTAssertEqual(materialStockWatchNextDelay(after: .notDue, now: now), materialStockWatchTickInterval)
        XCTAssertEqual(materialStockWatchNextDelay(after: nil, now: now), materialStockWatchTickInterval)
    }

    func testFailuresBackOffOrPauseAsTheOrderWatchDoes() {
        let now = Date(timeIntervalSince1970: 10_000_000)
        let tooMany = orderWatchFailureEffect(APIError.http(status: 429, body: "", retryAfter: "90", rateLimitReset: nil), now: now)
        XCTAssertEqual(tooMany.backoffUntil, now.addingTimeInterval(90))
        XCTAssertTrue(orderWatchFailureEffect(APIError.http(status: 401, body: "", retryAfter: nil, rateLimitReset: nil), now: now).pauseAccount)
        XCTAssertTrue(orderWatchFailureEffect(APIError.http(status: 403, body: "", retryAfter: nil, rateLimitReset: nil), now: now).pauseAccount)
        let transport = orderWatchFailureEffect(URLError(.timedOut), now: now)
        XCTAssertNil(transport.backoffUntil)
        XCTAssertFalse(transport.pauseAccount)
    }

    func testActivityGetsCountsOnly() {
        let keyring = product("Secret Keyring", materials: ["petg-red"])
        let check = savedProductStockCheck(products: [keyring], filaments: [petgOut])
        let detail = materialStockWatchActivityDetail(check)
        XCTAssertEqual(detail, "1 saved product can’t be ordered")
        XCTAssertFalse(detail.contains("Keyring"))
        XCTAssertFalse(detail.contains("PETG"))
        XCTAssertEqual(materialStockWatchActivityDetail(.checked([])), "No saved product affected")
        XCTAssertEqual(materialStockWatchActivityDetail(.notChecked), "Slant listed no materials; nothing checked")
    }
}
