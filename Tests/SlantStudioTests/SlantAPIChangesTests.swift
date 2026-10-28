import XCTest
@testable import SlantStudio

// MARK: - Fixtures

private func fixtureSpec() -> [String: Any] {
    [
        "openapi": "3.0.3",
        "info": ["title": "Slant 3D V2 API", "version": "2.0.0", "description": "Printing API",
                 "x-agent-hints": ["rate-limit": "100 requests per minute"]],
        "servers": [["url": "https://slant3dapi.com/v2/api"]],
        "security": [["bearerAuth": [Any]()]],
        "tags": [["name": "Orders", "description": "Orders"], ["name": "Files", "description": "Files"]],
        "paths": [
            "/orders": [
                "get": [
                    "tags": ["Orders"], "summary": "List orders",
                    "parameters": [
                        ["name": "status", "in": "query", "description": "Filter",
                         "schema": ["type": "string", "enum": ["DRAFT", "SUBMITTED", "PRINTING", "SHIPPED", "CANCELLED"]]],
                        ["name": "page", "in": "query", "schema": ["type": "integer"], "example": 1]
                    ],
                    "responses": ["200": ["description": "OK", "content": ["application/json": ["schema": ["$ref": "#/components/schemas/OrderList"]]]]]
                ],
                "post": [
                    "tags": ["Orders"],
                    "requestBody": ["content": ["application/json": ["schema": ["$ref": "#/components/schemas/NewOrder"]]]],
                    "responses": ["201": ["description": "Created"]]
                ]
            ],
            "/files": [
                "get": [
                    "tags": ["Files"],
                    "responses": ["200": ["description": "OK", "content": ["application/json": ["schema": ["$ref": "#/components/schemas/File"]]]]]
                ]
            ]
        ],
        "components": [
            "schemas": [
                "OrderList": ["type": "object", "properties": ["data": ["type": "array", "items": ["$ref": "#/components/schemas/Order"]]]],
                "Order": [
                    "type": "object", "required": ["publicId", "status"],
                    "properties": [
                        "publicId": ["type": "string"],
                        "status": ["type": "string", "enum": ["DRAFT", "SUBMITTED", "PRINTING", "SHIPPED", "CANCELLED"]],
                        "description": ["type": "string", "description": "A note"]
                    ]
                ],
                "NewOrder": ["type": "object", "required": ["platformId"], "properties": ["platformId": ["type": "string"], "metadata": ["type": "object"]]],
                "File": ["type": "object", "properties": ["publicFileServiceId": ["type": "string"]]],
                "Pagination": ["type": "object", "properties": ["count": ["type": "integer"]]]
            ],
            "securitySchemes": ["bearerAuth": ["type": "http", "scheme": "bearer"]]
        ]
    ]
}

/// Sets a value at a key path inside nested dictionaries (creating none: every key but the last must exist).
private func setting(_ value: Any?, at path: [String], in document: [String: Any]) -> [String: Any] {
    var copy = document
    guard let first = path.first else { return copy }
    if path.count == 1 {
        copy[first] = value
    } else {
        copy[first] = setting(value, at: Array(path.dropFirst()), in: copy[first] as? [String: Any] ?? [:])
    }
    return copy
}

private func units(_ document: [String: Any]) -> SlantAPISpecUnits {
    slantAPISpecUnits(document)!
}

private func difference(_ live: [String: Any], from bundled: [String: Any] = fixtureSpec()) -> SlantAPIDifference {
    slantAPIDifference(bundled: units(bundled), live: units(live))
}

private let changedToken = String(repeating: "a", count: 64)
private let otherToken = String(repeating: "b", count: 64)

// MARK: - Comparison

final class SlantAPIComparisonTests: XCTestCase {
    func testBundledSnapshotAgainstItselfIsUnchanged() throws {
        let data = try XCTUnwrap(slantAPIBundledSpecData())
        let document = try XCTUnwrap((try JSONSerialization.jsonObject(with: data)) as? [String: Any])
        let bundled = try XCTUnwrap(slantAPISpecUnits(document))
        XCTAssertGreaterThan(bundled.operations.count, 30)
        XCTAssertEqual(bundled.operationAreas["GET /orders"], "Orders")
        XCTAssertTrue(bundled.operationReach["GET /orders/{publicOrderId}"]?.contains("#/components/schemas/Order") ?? false)
        let comparison = try XCTUnwrap(slantAPICompare(liveData: data, bundled: bundled))
        XCTAssertTrue(comparison.difference.isEmpty)
        XCTAssertEqual(comparison.difference.areas, [])
        XCTAssertEqual(comparison.liveFingerprint, bundled.fingerprint)
    }

    /// The 26 Oct 2026 kind of change, replayed on the real bundled spec: the order status enum is replaced.
    func testReplacedOrderStatusesInTheBundledSpecNameOrders() throws {
        let data = try XCTUnwrap(slantAPIBundledSpecData())
        let document = try XCTUnwrap((try JSONSerialization.jsonObject(with: data)) as? [String: Any])
        let live = setting(["DRAFT", "PAID", "QUEUED", "SHIPPED", "DELIVERED", "CANCELED"],
                           at: ["components", "schemas", "Order", "properties", "status", "enum"], in: document)
        let result = slantAPIDifference(bundled: units(document), live: units(live))
        XCTAssertTrue(result.areas.contains("Orders"), "\(result.areas)")
        XCTAssertEqual(result.definitions, ["Order"])
        XCTAssertEqual(result.operations, [])
        // Rewording the same enum's description changes nothing.
        let reworded = setting("Statuses, newly described", at: ["components", "schemas", "Order", "properties", "status", "description"], in: document)
        XCTAssertTrue(slantAPIDifference(bundled: units(document), live: units(reworded)).isEmpty)
    }

    func testRemovedEnumValueNamesTheAreasThatUseTheSchema() {
        let live = setting(["DRAFT", "SUBMITTED", "PRINTING", "SHIPPED"], at: ["components", "schemas", "Order", "properties", "status", "enum"],
                           in: fixtureSpec())
        let result = difference(live)
        XCTAssertEqual(result.areas, ["Orders"])
        XCTAssertEqual(result.definitions, ["Order"])
        XCTAssertEqual(result.operations, [])
        XCTAssertFalse(result.isEmpty)
    }

    func testAddedRequiredPropertyIsAChange() {
        var live = setting(["platformId", "customer"], at: ["components", "schemas", "NewOrder", "required"], in: fixtureSpec())
        live = setting(["type": "object"], at: ["components", "schemas", "NewOrder", "properties", "customer"], in: live)
        XCTAssertEqual(difference(live).areas, ["Orders"])
        XCTAssertEqual(difference(live).definitions, ["NewOrder"])
    }

    func testWordingOnlyChangesAreIgnored() {
        var live = setting("Slant’s new wording", at: ["info", "description"], in: fixtureSpec())
        live = setting(["rate-limit": "120 requests per minute"], at: ["info", "x-agent-hints"], in: live)
        live = setting("Lists every order", at: ["paths", "/orders", "get", "summary"], in: live)
        live = setting("Another note", at: ["components", "schemas", "Order", "properties", "description", "description"], in: live)
        live = setting("Everything about orders", at: ["components", "schemas", "Order", "description"], in: live)
        live = setting(["publicId": "SLANT_1"], at: ["components", "schemas", "Order", "example"], in: live)
        live = setting([["name": "Files"], ["name": "Orders", "description": "Changed"]], at: ["tags"], in: live)
        // Reordered sets: enum values and required names.
        live = setting(["CANCELLED", "SHIPPED", "PRINTING", "SUBMITTED", "DRAFT"],
                       at: ["components", "schemas", "Order", "properties", "status", "enum"], in: live)
        live = setting(["status", "publicId"], at: ["components", "schemas", "Order", "required"], in: live)
        let result = difference(live)
        XCTAssertTrue(result.isEmpty, "\(result)")
        XCTAssertEqual(units(live).fingerprint, units(fixtureSpec()).fingerprint)
    }

    func testAPropertyNamedDescriptionIsStillCompared() {
        let live = setting(nil, at: ["components", "schemas", "Order", "properties", "description"], in: fixtureSpec())
        XCTAssertEqual(difference(live).areas, ["Orders"])
    }

    func testAddedAndRemovedOperationsUseTheirOwnTag() {
        let added = setting(["get": ["tags": ["Platforms"], "responses": ["200": ["description": "OK"]]]],
                            at: ["paths", "/platforms"], in: fixtureSpec())
        XCTAssertEqual(difference(added).areas, ["Platforms"])
        XCTAssertEqual(difference(added).operations, ["GET /platforms"])
        let removed = setting(nil, at: ["paths", "/files"], in: fixtureSpec())
        XCTAssertEqual(difference(removed).areas, ["Files"])
        XCTAssertEqual(difference(removed).operations, ["GET /files"])
    }

    func testParameterChangeCountsForItsOperation() {
        let live = setting([["name": "status", "in": "query", "schema": ["type": "string", "enum": ["DRAFT"]]]],
                           at: ["paths", "/orders", "get", "parameters"], in: fixtureSpec())
        XCTAssertEqual(difference(live).operations, ["GET /orders"])
        XCTAssertEqual(difference(live).areas, ["Orders"])
    }

    func testUnusedDefinitionsAuthenticationAndGeneralAreas() {
        let unused = setting(["type": "object"], at: ["components", "schemas", "Pagination"], in: fixtureSpec())
        XCTAssertEqual(difference(unused).areas, [slantAPISharedDefinitionsArea])
        let auth = setting(["type": "apiKey", "in": "header", "name": "X-Key"], at: ["components", "securitySchemes", "bearerAuth"], in: fixtureSpec())
        XCTAssertEqual(difference(auth).areas, [slantAPIAuthenticationArea])
        let servers = setting([["url": "https://api.slant3d.com/v3"]], at: ["servers"], in: fixtureSpec())
        XCTAssertEqual(difference(servers).areas, [slantAPIGeneralArea])
        XCTAssertTrue(difference(servers).general)
        let version = setting("3.0.0", at: ["info", "version"], in: fixtureSpec())
        XCTAssertEqual(difference(version).areas, [slantAPIGeneralArea])
    }

    func testAreasSortTagsFirstThenSpecialAreas() {
        XCTAssertEqual(slantAPISortedAreas(["General", "Orders", "Shared definitions", "Files", "Authentication"]),
                       ["Files", "Orders", "Authentication", "Shared definitions", "General"])
        XCTAssertEqual(slantAPIAreaName(nil), "Other")
        XCTAssertEqual(slantAPIAreaName("  Orders\n"), "Orders")
        XCTAssertEqual(slantAPIAreaName(String(repeating: "x", count: 90)).count, 40)
    }

    /// A large or deeply nested reply (within the 2 MB cap) is compared without running away.
    func testLargeAndDeeplyNestedSpecsStayBounded() throws {
        var nested: Any = ["type": "string"]
        for _ in 0..<150 { nested = ["type": "array", "items": nested] }
        var live = setting(nested, at: ["components", "schemas", "Deep"], in: fixtureSpec())
        live = setting((0..<40_000).map { "VALUE_\($0)" }, at: ["components", "schemas", "Order", "properties", "status", "enum"], in: live)
        live = setting((0..<5_000).map { ["name": "p\($0)", "in": "query", "schema": ["type": "string"]] },
                       at: ["paths", "/orders", "get", "parameters"], in: live)
        let data = try JSONSerialization.data(withJSONObject: live)
        XCTAssertLessThan(data.count, slantAPISpecMaxBytes)
        let started = Date()
        let comparison = try XCTUnwrap(slantAPICompare(liveData: data, bundled: units(fixtureSpec())))
        XCTAssertLessThan(Date().timeIntervalSince(started), 20)
        XCTAssertEqual(comparison.difference.areas, ["Orders", slantAPISharedDefinitionsArea])
    }

    func testUnreadableRepliesCompareAsNil() {
        let bundled = units(fixtureSpec())
        XCTAssertNil(slantAPICompare(liveData: Data("{not json".utf8), bundled: bundled))
        XCTAssertNil(slantAPICompare(liveData: Data("[1,2,3]".utf8), bundled: bundled))
        XCTAssertNil(slantAPICompare(liveData: Data(#"{"openapi":"3.0.3"}"#.utf8), bundled: bundled))
        XCTAssertNil(slantAPICompare(liveData: Data(count: slantAPISpecMaxBytes + 1), bundled: bundled))
        let data = try! JSONSerialization.data(withJSONObject: fixtureSpec())
        XCTAssertEqual(slantAPICompare(liveData: data, bundled: bundled)?.difference.isEmpty, true)
    }
}

// MARK: - Runtime signals and the notice

final class SlantAPISignalsTests: XCTestCase {
    func testStatusWordsAreSanitisedAndRecognisedStatusesIgnored() {
        XCTAssertEqual(slantAPIUnrecognisedStatusWord("ON_HOLD"), "ON_HOLD")
        XCTAssertEqual(slantAPIUnrecognisedStatusWord(" on hold\n"), "ON_HOLD")
        XCTAssertEqual(slantAPIUnrecognisedStatusWord("awaiting-pickup"), "AWAITING_PICKUP")
        XCTAssertNil(slantAPIUnrecognisedStatusWord("shipped"))
        XCTAssertNil(slantAPIUnrecognisedStatusWord("CANCELED"))
        XCTAssertNil(slantAPIUnrecognisedStatusWord(" Draft "))
        XCTAssertNil(slantAPIUnrecognisedStatusWord(""))
        XCTAssertNil(slantAPIUnrecognisedStatusWord("---"))
        XCTAssertNil(slantAPIUnrecognisedStatusWord(5))
        XCTAssertNil(slantAPIUnrecognisedStatusWord(NSNull()))
        XCTAssertNil(slantAPIUnrecognisedStatusWord(nil))
        let long = slantAPIUnrecognisedStatusWord(String(repeating: "Q", count: 500))
        XCTAssertEqual(long?.count, slantAPIMaxStatusWordLength)
        // Only A–Z, 0–9 and _ survive: no customer text, markup or newlines can reach Activity.
        let odd = slantAPIUnrecognisedStatusWord("Ada <script>\nLovelace@example.com")!
        XCTAssertTrue(odd.allSatisfy { "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_".contains($0) }, odd)
    }

    func testDistinctWordsAreCappedAndReportedOnce() {
        var signals = SlantAPIRuntimeSignals()
        XCTAssertEqual(signals.note(statusValues: ["ON_HOLD", "on_hold", "SHIPPED", nil]), ["ON_HOLD"])
        XCTAssertEqual(signals.note(statusValues: ["ON_HOLD"]), [])
        let many = (1...15).map { "NEW_\($0)" }
        let added = signals.note(statusValues: many)
        XCTAssertEqual(added.count, slantAPIMaxStatusWords - 1)
        XCTAssertEqual(signals.statuses.count, slantAPIMaxStatusWords)
        XCTAssertTrue(signals.moreStatuses)
        XCTAssertTrue(signals.noteUnreadableOrderList())
        XCTAssertFalse(signals.noteUnreadableOrderList())
        XCTAssertEqual(signals.unreadableOrderLists, 2)
    }

    func testUnreadableOrderLists() {
        let counted: [String: Any] = ["count": 5, "totalPages": 1]
        XCTAssertTrue(slantAPIOrderListLooksUnreadable(records: [], pagination: counted, firstPage: true))
        XCTAssertFalse(slantAPIOrderListLooksUnreadable(records: [], pagination: counted, firstPage: false))
        XCTAssertFalse(slantAPIOrderListLooksUnreadable(records: [], pagination: ["count": 0], firstPage: true))
        XCTAssertFalse(slantAPIOrderListLooksUnreadable(records: [], pagination: nil, firstPage: true))
        let withStatus = Record(values: ["publicId": "SLANT_1", "status": "DRAFT"])
        let wrapped = Record(values: ["order": ["publicId": "SLANT_2", "status": "SHIPPED"]])
        let without = Record(values: ["publicId": "SLANT_3", "state": "DRAFT"])
        XCTAssertFalse(slantAPIOrderListLooksUnreadable(records: [withStatus], pagination: counted, firstPage: true))
        XCTAssertFalse(slantAPIOrderListLooksUnreadable(records: [wrapped], pagination: nil, firstPage: false))
        XCTAssertFalse(slantAPIOrderListLooksUnreadable(records: [without, withStatus], pagination: nil, firstPage: true))
        XCTAssertTrue(slantAPIOrderListLooksUnreadable(records: [without], pagination: nil, firstPage: false))
    }

    /// The notice says Studio treats unrecognised statuses with caution; this is what that sentence relies on.
    func testUnrecognisedStatusesAreTreatedWithCaution() {
        let status = "ON_HOLD"
        XCTAssertFalse(orderCanRequestCancellation(status))
        XCTAssertFalse(spendReportCountedStatuses.contains(status))
        XCTAssertFalse(orderPlacedStatuses.contains(status))
        let order: [String: Any] = ["status": status, "createdAt": "2026-09-01T00:00:00Z", "arriveByDate": "2026-09-05"]
        XCTAssertNil(orderAttention(order, now: Date(timeIntervalSince1970: 1_793_000_000)))
    }

    func testAreaListText() {
        XCTAssertEqual(slantAPIAreaListText([]), "")
        XCTAssertEqual(slantAPIAreaListText(["Orders"]), "Orders")
        XCTAssertEqual(slantAPIAreaListText(["Files", "Orders"]), "Files and Orders")
        XCTAssertEqual(slantAPIAreaListText(["Files", "Orders", "Platforms"]), "Files, Orders and Platforms")
        XCTAssertEqual(slantAPIAreaListText(["A", "B", "C", "D", "E"]), "A, B, C and 2 more")
    }

    func testNoticeCopy() {
        let later = Date(timeIntervalSince1970: 1_794_000_000)
        let dated = slantAPISpecChangeSentence(areas: ["Orders"], changedOn: later)
        XCTAssertTrue(dated.hasPrefix("Slant changed its API on "), dated)
        XCTAssertTrue(dated.contains("(Orders), after this version of Studio was made. Some features may not work as expected until Studio is updated."), dated)
        XCTAssertEqual(slantAPISpecChangeSentence(areas: ["Files", "Orders"], changedOn: nil),
                       "Slant’s API has changed (Files and Orders) since this version of Studio was made. Some features may not work as expected until Studio is updated.")
        XCTAssertEqual(slantAPIStatusSentence(["ON_HOLD"], more: false),
                       "Slant sent an order status this version of Studio doesn’t recognise (ON_HOLD). Studio treats such orders with caution: it offers no Cancel for them, leaves them out of spending, never marks them late and doesn’t treat them as placed.")
        XCTAssertTrue(slantAPIStatusSentence(["A", "B"], more: true).hasPrefix("Slant sent order statuses this version of Studio doesn’t recognise (A, B and others)."))
        // A Last-Modified no later than the bundled copy's isn't shown as the change's date.
        var record = SlantAPICheckRecord(checkedAt: later, areas: ["Orders"], changeToken: changedToken, changedOn: slantAPIBundledSpecDate)
        XCTAssertNil(slantAPIChangeDate(record))
        record.changedOn = later
        XCTAssertEqual(slantAPIChangeDate(record), later)
    }

    func testNoticeLinesAndDismissal() {
        var record = SlantAPICheckRecord(checkedAt: Date(), areas: ["Orders"], changeToken: changedToken)
        var signals = SlantAPIRuntimeSignals()
        var dismissal = SlantAPINoticeDismissal()
        XCTAssertEqual(slantAPINoticeLines(record: SlantAPICheckRecord(), signals: signals, dismissal: dismissal), [])
        XCTAssertEqual(slantAPINoticeLines(record: record, signals: signals, dismissal: dismissal).count, 1)

        // Dismiss hides it.
        (record, dismissal) = slantAPIDismissing(record: record, signals: signals, dismissal: dismissal)
        XCTAssertEqual(record.dismissedToken, changedToken)
        XCTAssertEqual(slantAPINoticeLines(record: record, signals: signals, dismissal: dismissal), [])

        // A new unrecognised status shows only what's new.
        _ = signals.note(statusValues: ["ON_HOLD"])
        let lines = slantAPINoticeLines(record: record, signals: signals, dismissal: dismissal)
        XCTAssertEqual(lines, [slantAPIStatusSentence(["ON_HOLD"], more: false)])
        (record, dismissal) = slantAPIDismissing(record: record, signals: signals, dismissal: dismissal)
        XCTAssertEqual(slantAPINoticeLines(record: record, signals: signals, dismissal: dismissal), [])

        // A wording-only edit (same fingerprint) keeps it dismissed; a further change shows it again.
        let same = SlantAPIComparison(difference: SlantAPIDifference(areas: ["Orders"], definitions: ["Order"]), liveFingerprint: changedToken)
        record = slantAPIRecordAfterFetch(record, comparison: same, etag: "W/\"2\"", lastModified: nil, now: Date())
        XCTAssertEqual(slantAPINoticeLines(record: record, signals: signals, dismissal: dismissal), [])
        let further = SlantAPIComparison(difference: SlantAPIDifference(areas: ["Files", "Orders"], operations: ["GET /files"]), liveFingerprint: otherToken)
        record = slantAPIRecordAfterFetch(record, comparison: further, etag: "W/\"3\"", lastModified: nil, now: Date())
        XCTAssertEqual(slantAPINoticeLines(record: record, signals: signals, dismissal: dismissal).count, 1)

        // Unreadable lists show until dismissed for the session.
        _ = signals.noteUnreadableOrderList()
        XCTAssertTrue(slantAPINoticeLines(record: record, signals: signals, dismissal: dismissal).contains(slantAPIUnreadableSentence))
        (record, dismissal) = slantAPIDismissing(record: record, signals: signals, dismissal: dismissal)
        _ = signals.noteUnreadableOrderList()
        XCTAssertEqual(slantAPINoticeLines(record: record, signals: signals, dismissal: dismissal), [])
    }

    func testSettingsStateText() {
        XCTAssertEqual(slantAPISettingsStateText(record: SlantAPICheckRecord(), bundleAvailable: true), "Not checked yet.")
        XCTAssertEqual(slantAPISettingsStateText(record: SlantAPICheckRecord(checkedAt: Date()), bundleAvailable: true),
                       "Matches the API this version of Studio was made for.")
        let changed = SlantAPICheckRecord(checkedAt: Date(), areas: ["Files", "Orders"], changeToken: changedToken)
        XCTAssertEqual(slantAPISettingsStateText(record: changed, bundleAvailable: true),
                       "Changed since this version of Studio was made: Files and Orders.")
        XCTAssertTrue(slantAPISettingsStateText(record: changed, bundleAvailable: false).contains("missing"))
        XCTAssertEqual(slantAPIChangedOperationsText(SlantAPIDifference(areas: ["Orders"], operations: ["GET /orders"], definitions: ["Order"])),
                       "Changed operations: GET /orders · definitions: Order")
        XCTAssertEqual(slantAPIChangedOperationsText(SlantAPIDifference(areas: ["Orders"], definitions: ["Order"])), "Definitions: Order")
    }
}

// MARK: - Record, schedule and request

final class SlantAPICheckRecordTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_793_100_000)

    func testRecordAfterFetch() {
        let fresh = SlantAPICheckRecord(bundledFingerprint: changedToken)
        let unchanged = SlantAPIComparison(difference: SlantAPIDifference(), liveFingerprint: otherToken)
        var record = slantAPIRecordAfterFetch(fresh, comparison: unchanged, etag: "W/\"1e457\"", lastModified: "Mon, 26 Oct 2026 21:09:58 GMT", now: now)
        XCTAssertEqual(record.checkedAt, now)
        XCTAssertEqual(record.etag, "W/\"1e457\"")
        XCTAssertFalse(record.hasChange)

        let changed = SlantAPIComparison(difference: SlantAPIDifference(areas: ["Orders"], definitions: ["Order"]), liveFingerprint: otherToken)
        record = slantAPIRecordAfterFetch(record, comparison: changed, etag: "W/\"2\"", lastModified: "Tue, 03 Nov 2026 09:00:00 GMT", now: now)
        XCTAssertTrue(record.hasChange)
        XCTAssertEqual(record.changeToken, otherToken)
        let firstSeen = record.changedOn
        XCTAssertEqual(firstSeen, slantAPIHTTPDate("Tue, 03 Nov 2026 09:00:00 GMT"))
        // The same change with a newer Last-Modified (a wording edit) keeps its first-seen date.
        record = slantAPIRecordAfterFetch(record, comparison: changed, etag: "W/\"3\"", lastModified: "Wed, 04 Nov 2026 09:00:00 GMT", now: now)
        XCTAssertEqual(record.changedOn, firstSeen)
        XCTAssertEqual(record.lastModified, "Wed, 04 Nov 2026 09:00:00 GMT")
        // Matching again clears it.
        record = slantAPIRecordAfterFetch(record, comparison: unchanged, etag: nil, lastModified: nil, now: now)
        XCTAssertFalse(record.hasChange)
        XCTAssertNil(record.changedOn)
        XCTAssertNil(record.etag)
    }

    func testEncodeDecodeIsLenientAndTiedToTheBundledCopy() {
        let record = SlantAPICheckRecord(bundledFingerprint: changedToken, etag: "W/\"1\"", lastModified: "Mon, 26 Oct 2026 21:09:58 GMT",
                                         checkedAt: now, attemptedAt: now, areas: ["Orders"], changeToken: otherToken,
                                         changedOn: now, dismissedToken: otherToken)
        let encoded = encodeSlantAPICheckRecord(record)
        XCTAssertEqual(decodeSlantAPICheckRecord(encoded, bundledFingerprint: changedToken), record)
        // Another Studio build (another bundled copy) starts afresh.
        XCTAssertEqual(decodeSlantAPICheckRecord(encoded, bundledFingerprint: otherToken), SlantAPICheckRecord(bundledFingerprint: otherToken))
        XCTAssertEqual(decodeSlantAPICheckRecord("junk", bundledFingerprint: changedToken), SlantAPICheckRecord(bundledFingerprint: changedToken))
        var damaged = encoded
        damaged["etag"] = "bad\nvalue"
        damaged["checkedAt"] = true
        damaged["changeToken"] = "short"
        damaged["areas"] = ["Orders", 5, "Orders\n", String(repeating: "z", count: 100)]
        let decoded = decodeSlantAPICheckRecord(damaged, bundledFingerprint: changedToken)
        XCTAssertNil(decoded.etag)
        XCTAssertNil(decoded.checkedAt)
        // Cache headers without a saved comparison are dropped, so a 304 can't be read as "unchanged".
        XCTAssertNil(decoded.lastModified)
        XCTAssertNil(decoded.changeToken)
        XCTAssertEqual(decoded.areas, [])
        XCTAssertEqual(slantAPISavedAreas(["Orders", "Orders\n", String(repeating: "z", count: 100)]), ["Orders", String(repeating: "z", count: 40)])
    }

    func testScheduling() {
        XCTAssertEqual(slantAPICheckDecision(hasKey: false, bundleAvailable: true, lastAttempt: nil, now: now), .wait(slantAPIIdleRecheck))
        XCTAssertEqual(slantAPICheckDecision(hasKey: true, bundleAvailable: false, lastAttempt: nil, now: now), .wait(slantAPIIdleRecheck))
        XCTAssertEqual(slantAPICheckDecision(hasKey: true, bundleAvailable: true, lastAttempt: nil, now: now), .checkNow)
        XCTAssertEqual(slantAPICheckDecision(hasKey: true, bundleAvailable: true, lastAttempt: now.addingTimeInterval(-3600), now: now),
                       .wait(slantAPIMaxWait))
        XCTAssertEqual(slantAPICheckDecision(hasKey: true, bundleAvailable: true, lastAttempt: now.addingTimeInterval(-(24 * 3600 - 120)), now: now),
                       .wait(120))
        XCTAssertEqual(slantAPICheckDecision(hasKey: true, bundleAvailable: true, lastAttempt: now.addingTimeInterval(-24 * 3600), now: now), .checkNow)
        XCTAssertEqual(slantAPICheckDecision(hasKey: true, bundleAvailable: true, lastAttempt: now.addingTimeInterval(600), now: now), .checkNow)
    }

    func testSpecRequestIsKeylessHTTPSAndConditionalOnlyAfterAComparison() {
        let plain = slantAPISpecRequest(etag: nil, lastModified: nil)
        XCTAssertEqual(plain.url?.scheme, "https")
        XCTAssertEqual(plain.url?.host, "slant3dapi.com")
        XCTAssertEqual(plain.url?.path, "/v2/api/openapi.json")
        XCTAssertEqual(plain.httpMethod, "GET")
        XCTAssertNil(plain.value(forHTTPHeaderField: "Authorization"))
        XCTAssertNil(plain.value(forHTTPHeaderField: "If-None-Match"))
        XCTAssertFalse(plain.httpShouldHandleCookies)
        XCTAssertTrue(slantAPISpecRequestIsSafe(plain))

        let unsaved = SlantAPICheckRecord(etag: "W/\"1\"", lastModified: "Mon, 26 Oct 2026 21:09:58 GMT")
        XCTAssertNil(slantAPIConditionalHeaders(unsaved).etag)
        var saved = unsaved
        saved.checkedAt = now
        let headers = slantAPIConditionalHeaders(saved)
        let conditional = slantAPISpecRequest(etag: headers.etag, lastModified: headers.lastModified)
        XCTAssertEqual(conditional.value(forHTTPHeaderField: "If-None-Match"), "W/\"1\"")
        XCTAssertEqual(conditional.value(forHTTPHeaderField: "If-Modified-Since"), "Mon, 26 Oct 2026 21:09:58 GMT")
        XCTAssertNil(conditional.value(forHTTPHeaderField: "Authorization"))
        XCTAssertNil(slantAPISpecRequest(etag: "bad\r\nX: 1", lastModified: nil).value(forHTTPHeaderField: "If-None-Match"))

        var withKey = plain
        withKey.setValue("Bearer sl-secret", forHTTPHeaderField: "Authorization")
        XCTAssertFalse(slantAPISpecRequestIsSafe(withKey))
        var insecure = plain
        insecure.url = URL(string: "http://slant3dapi.com/v2/api/openapi.json")
        XCTAssertFalse(slantAPISpecRequestIsSafe(insecure))
        var elsewhere = plain
        elsewhere.url = URL(string: "https://example.com/v2/api/openapi.json")
        XCTAssertFalse(slantAPISpecRequestIsSafe(elsewhere))
    }
}

// MARK: - The fetcher against a local stub (no network)

final class SlantAPISpecStubProtocol: URLProtocol {
    struct Reply {
        var status: Int
        var headers: [String: String] = [:]
        var chunks: [Data] = []
    }
    nonisolated(unsafe) static var reply = Reply(status: 200)
    nonisolated(unsafe) static var lastRequest: URLRequest?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lastRequest = request
        let reply = Self.reply
        let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: reply.headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        for chunk in reply.chunks { client?.urlProtocol(self, didLoad: chunk) }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

final class SlantAPISpecFetcherTests: XCTestCase {
    private func fetch(_ request: URLRequest = slantAPISpecRequest(etag: nil, lastModified: nil)) async -> Result<SlantAPISpecFetchResult, Error> {
        do {
            return .success(try await SlantAPISpecFetcher(protocolClasses: [SlantAPISpecStubProtocol.self]).fetch(request))
        } catch {
            return .failure(error)
        }
    }

    private func failure(_ result: Result<SlantAPISpecFetchResult, Error>) -> SlantAPISpecFetchError? {
        if case .failure(let error) = result { return error as? SlantAPISpecFetchError }
        return nil
    }

    func testFetchedReplyCarriesCacheHeadersAndNoCredentials() async {
        SlantAPISpecStubProtocol.reply = .init(status: 200, headers: ["ETag": "W/\"1e457\"", "Last-Modified": "Mon, 26 Oct 2026 21:09:58 GMT"],
                                               chunks: [Data(#"{"paths":{}}"#.utf8)])
        let result = await fetch()
        guard case .success(.fetched(let data, let etag, let lastModified)) = result else { return XCTFail("\(result)") }
        XCTAssertEqual(data, Data(#"{"paths":{}}"#.utf8))
        XCTAssertEqual(etag, "W/\"1e457\"")
        XCTAssertEqual(lastModified, "Mon, 26 Oct 2026 21:09:58 GMT")
        let sent = SlantAPISpecStubProtocol.lastRequest
        XCTAssertEqual(sent?.url?.scheme, "https")
        XCTAssertNil(sent?.value(forHTTPHeaderField: "Authorization"))
        XCTAssertNil(sent?.value(forHTTPHeaderField: "Cookie"))
    }

    func testNotModifiedOnlyForConditionalRequests() async {
        SlantAPISpecStubProtocol.reply = .init(status: 304)
        let conditional = await fetch(slantAPISpecRequest(etag: "W/\"1\"", lastModified: nil))
        guard case .success(.notModified) = conditional else { return XCTFail("\(conditional)") }
        XCTAssertEqual(SlantAPISpecStubProtocol.lastRequest?.value(forHTTPHeaderField: "If-None-Match"), "W/\"1\"")
        do { let error = failure(await fetch()); XCTAssertEqual(error, .unexpectedNotModified) }
    }

    func testServerErrorsRedirectsAndOversizedRepliesFail() async {
        SlantAPISpecStubProtocol.reply = .init(status: 500, chunks: [Data("oops".utf8)])
        do { let error = failure(await fetch()); XCTAssertEqual(error, .http(500)) }
        SlantAPISpecStubProtocol.reply = .init(status: 302, headers: ["Location": "https://example.com/spec.json"])
        do { let error = failure(await fetch()); XCTAssertEqual(error, .redirected(302)) }
        SlantAPISpecStubProtocol.reply = .init(status: 200, headers: ["Content-Length": String(slantAPISpecMaxBytes + 1)])
        do { let error = failure(await fetch()); XCTAssertEqual(error, .tooLarge) }
        let chunk = Data(count: 512 * 1024)
        SlantAPISpecStubProtocol.reply = .init(status: 200, chunks: Array(repeating: chunk, count: 5))
        do { let error = failure(await fetch()); XCTAssertEqual(error, .tooLarge) }
    }

    func testUnsafeRequestsAreNeverSent() async {
        SlantAPISpecStubProtocol.lastRequest = nil
        var request = slantAPISpecRequest(etag: nil, lastModified: nil)
        request.setValue("Bearer sl-secret", forHTTPHeaderField: "Authorization")
        do { let error = failure(await fetch(request)); XCTAssertEqual(error, .unsafeRequest) }
        XCTAssertNil(SlantAPISpecStubProtocol.lastRequest)
    }
}
