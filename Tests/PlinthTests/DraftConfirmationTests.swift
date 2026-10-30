import XCTest
@testable import Plinth

final class DraftConfirmationTests: XCTestCase {
    // MARK: Building the marker

    func testMarkerIsAddedWhenThereIsRoom() {
        let marker = newStudioDraftMarker()
        XCTAssertNotEqual(marker, newStudioDraftMarker(), "Every press gets a fresh marker")
        XCTAssertEqual(marker, marker.lowercased())
        let metadata = orderMetadataAddingDraftMarker(["shopOrder": "1001"], marker: marker)
        XCTAssertEqual(metadata["studioDraftId"] as? String, marker)
        XCTAssertEqual(metadata["shopOrder"] as? String, "1001")
        XCTAssertEqual((orderMetadataAddingDraftMarker([:], marker: marker))["studioDraftId"] as? String, marker)
    }

    func testMarkerRespectsTheTenFieldLimitAndTheSellersOwnKey() {
        var full: [String: Any] = [:]
        for index in 0..<10 { full["k\(index)"] = "v" }
        let unchanged = orderMetadataAddingDraftMarker(full, marker: "m")
        XCTAssertEqual(unchanged.count, 10)
        XCTAssertNil(unchanged["studioDraftId"])
        var nine: [String: Any] = [:]
        for index in 0..<9 { nine["k\(index)"] = "v" }
        XCTAssertEqual(orderMetadataAddingDraftMarker(nine, marker: "m").count, 10)
        let own = orderMetadataAddingDraftMarker(["studioDraftId": "typed"], marker: "m")
        XCTAssertEqual(own["studioDraftId"] as? String, "typed", "A seller's own value is never overwritten")
        XCTAssertNil(orderMetadataAddingDraftMarker([:], marker: "  ")["studioDraftId"])
    }

    func testDraftBodyCarriesTheMarkerThroughOrderDraftPayload() throws {
        let marker = newStudioDraftMarker()
        let body = try orderDraftPayload(
            platformID: "plat", ownerID: "", email: "ada@example.com", recipientName: "Ada",
            line1: "1 Main St", line2: "", city: "Springfield", state: "IL", zip: "62701", country: "US",
            paymentID: "", metadata: orderMetadataAddingDraftMarker([:], marker: marker), options: [:],
            lines: [OrderLine(reference: "file", filamentID: "fil", quantity: 1)])
        XCTAssertEqual(orderDraftMarker(body), marker)
        XCTAssertEqual((body["metadata"] as? [String: Any])?.count, 1)
    }

    func testOnlyStudiosOwnMarkerIsRemembered() {
        XCTAssertEqual(orderDraftMarkerSent(["metadata": ["studioDraftId": "abc"]], generated: "ABC"), "abc")
        XCTAssertNil(orderDraftMarkerSent(["metadata": ["studioDraftId": "typed"]], generated: "abc"),
                     "A seller's own value under the key could match another order")
        XCTAssertNil(orderDraftMarkerSent(["metadata": ["k": "v"]], generated: "abc"))
        XCTAssertNil(orderDraftMarkerSent([:], generated: ""))
    }

    func testImportMetadataGainsTheMarkerOnlyWhenGiven() {
        let plain = orderImportMetadata(source: .etsy, sourceOrderID: "3141")
        XCTAssertEqual(plain.count, 2)
        XCTAssertNil(plain["studioDraftId"])
        let marked = orderImportMetadata(source: .etsy, sourceOrderID: "3141", draftMarker: "abc")
        XCTAssertEqual(marked.count, 3)
        XCTAssertEqual(marked["studioDraftId"] as? String, "abc")
        XCTAssertEqual(marked["sourceOrderId"] as? String, "3141")
    }

    // MARK: Matching

    func testReadingTheMarkerFromOrders() {
        XCTAssertEqual(orderDraftMarker(["metadata": ["studioDraftId": " ABC "]]), "abc")
        XCTAssertEqual(orderDraftMarker(["order": ["metadata": ["studioDraftId": "abc"]]]), "abc")
        XCTAssertNil(orderDraftMarker(["metadata": NSNull()]))
        XCTAssertNil(orderDraftMarker([:]))
        XCTAssertNil(orderDraftMarker(["metadata": "studioDraftId=abc"]), "Metadata that isn't an object has no marker")
        XCTAssertNil(orderDraftMarker(["metadata": ["abc"]]))
        XCTAssertNil(orderDraftMarker(["metadata": ["studioDraftId": 12]]), "A non-text value isn't a marker")
        XCTAssertNil(orderDraftMarker(["metadata": ["studioDraftId": ""]]))
        XCTAssertNil(orderDraftMarker(["metadata": ["studioDraftId": NSNull()]]))
        XCTAssertNil(orderDraftMarker(["metadata": ["source": "csv", "sourceOrderId": "T-1002"]]))
    }

    func testFindingOrdersCarryingMarkers() {
        let records = [
            Record(values: ["publicId": "SO-1", "metadata": NSNull()]),
            Record(values: ["publicId": "SO-2", "metadata": ["studioDraftId": "m2"]]),
            Record(values: ["publicId": "SO-3", "metadata": ["studioDraftId": "other"]]),
            Record(values: ["publicId": "SO-4", "metadata": ["studioDraftId": "M2"]]),
            Record(values: ["metadata": ["studioDraftId": "m5"]])
        ]
        let found = ordersCarryingDraftMarkers(records, markers: ["m2", "m5", "missing"])
        XCTAssertEqual(Set(found.keys), ["m2"], "An order without an ID can't be shown, so it doesn't count")
        XCTAssertEqual(found["m2"]?.id, "SO-2", "The first match wins")
        XCTAssertTrue(ordersCarryingDraftMarkers([], markers: ["m2"]).isEmpty)
        XCTAssertTrue(ordersCarryingDraftMarkers(records, markers: []).isEmpty)
    }

    // MARK: Attempts

    func testAttemptRecordsTheMarkerAndPlatform() {
        let date = Date(timeIntervalSince1970: 1_000)
        let attempts = unconfirmedDraftAttempts(previous: [], attempt: .failed(URLError(.timedOut)), recipient: " Ada ",
                                                date: date, marker: "m1", platformID: " plat ")
        XCTAssertEqual(attempts, [UnconfirmedDraftAttempt(recipient: "Ada", date: date, marker: "m1", platformID: "plat")])
        // A definite refusal leaves the list as it was.
        XCTAssertEqual(unconfirmedDraftAttempts(previous: attempts, attempt: .failed(APIError.http(status: 422, body: "{}", retryAfter: nil, rateLimitReset: nil)),
                                                recipient: "Grace", date: date, marker: "m2"), attempts)
        // A success for another recipient leaves Ada's attempt; one for Ada clears it.
        XCTAssertEqual(unconfirmedDraftAttempts(previous: attempts, attempt: .succeeded, recipient: "Grace", date: date, marker: "m2"), attempts)
        XCTAssertEqual(unconfirmedDraftAttempts(previous: attempts, attempt: .succeeded, recipient: "ada", date: date, marker: "m2"), [])
    }

    func testFoundMarkersRemoveOnlyTheirAttempts() {
        let date = Date()
        let a = UnconfirmedDraftAttempt(recipient: "Ada", date: date, marker: "m1", platformID: "p")
        let b = UnconfirmedDraftAttempt(recipient: "Grace", date: date, marker: "m2", platformID: "p")
        let unmarked = UnconfirmedDraftAttempt(recipient: "Alan", date: date)
        XCTAssertEqual(unconfirmedDraftAttempts([a, b, unmarked], confirmedMarkers: ["M1"]), [b, unmarked])
        XCTAssertEqual(unconfirmedDraftAttempts([a, b], confirmedMarkers: ["m1", "m2"]), [], "None left lifts Create Anyway")
        XCTAssertEqual(unconfirmedDraftAttempts([a, b, unmarked], confirmedMarkers: []), [a, b, unmarked], "Absence proves nothing")
    }

    // MARK: Paging

    func testPagingStopsWhenFoundAtThePageCapAtTheEndOrAtALowRateLimit() {
        let now = Date()
        XCTAssertTrue(draftMarkerCheckShouldReadNextPage(page: 1, recordCount: 100, pagination: nil, markersStillMissing: 1, rateLimit: nil, now: now))
        XCTAssertFalse(draftMarkerCheckShouldReadNextPage(page: 1, recordCount: 100, pagination: nil, markersStillMissing: 0, rateLimit: nil, now: now))
        XCTAssertFalse(draftMarkerCheckShouldReadNextPage(page: 3, recordCount: 100, pagination: nil, markersStillMissing: 1, rateLimit: nil, now: now))
        XCTAssertFalse(draftMarkerCheckShouldReadNextPage(page: 1, recordCount: 40, pagination: nil, markersStillMissing: 1, rateLimit: nil, now: now))
        XCTAssertFalse(draftMarkerCheckShouldReadNextPage(page: 1, recordCount: 100, pagination: ["totalPages": 1], markersStillMissing: 1, rateLimit: nil, now: now))
        let low = RateLimitInfo(limit: 100, remaining: 5, reset: now.addingTimeInterval(30))
        XCTAssertFalse(draftMarkerCheckShouldReadNextPage(page: 1, recordCount: 100, pagination: nil, markersStillMissing: 1, rateLimit: low, now: now))
        let reset = RateLimitInfo(limit: 100, remaining: 5, reset: now.addingTimeInterval(-1))
        XCTAssertTrue(draftMarkerCheckShouldReadNextPage(page: 1, recordCount: 100, pagination: nil, markersStillMissing: 1, rateLimit: reset, now: now))
        let plenty = RateLimitInfo(limit: 100, remaining: 50, reset: now.addingTimeInterval(30))
        XCTAssertTrue(draftMarkerCheckShouldReadNextPage(page: 2, recordCount: 100, pagination: nil, markersStillMissing: 2, rateLimit: plenty, now: now))
    }

    // MARK: Messages

    func testCheckOutcomeMessages() {
        let time: (Date) -> String = { _ in "2:32 PM" }
        let date = Date()
        let ada = UnconfirmedDraftAttempt(recipient: "Ada Lovelace", date: date, marker: "m1", platformID: "p")
        var result = DraftMarkerSearchResult()
        result.ordersRead = 300
        let missing = draftCreateCheckOutcome(attempts: [ada], result: result, time: time)
        XCTAssertEqual(missing.message, "Slant has no matching draft among your 300 newest orders. It probably wasn’t created; if you create it again, check the list afterwards.")
        XCTAssertFalse(missing.allConfirmed)
        XCTAssertEqual(missing.foundOrderIDs, [])

        result.found = ["m1": Record(values: ["publicId": "SO-9"])]
        let found = draftCreateCheckOutcome(attempts: [ada], result: result, time: time)
        XCTAssertEqual(found.message, "Found: Slant created the draft for Ada Lovelace at 2:32 PM (order SO-9).")
        XCTAssertTrue(found.allConfirmed)
        XCTAssertEqual(found.foundOrderIDs, ["SO-9"])
        XCTAssertEqual(found.foundOrderNumbers, ["SO-9"])

        let unmarked = UnconfirmedDraftAttempt(recipient: "Alan", date: date)
        let mixed = draftCreateCheckOutcome(attempts: [ada, unmarked], result: result, time: time)
        XCTAssertFalse(mixed.allConfirmed)
        XCTAssertTrue(mixed.message.contains("went without Plinth’s reference"))
        XCTAssertFalse(mixed.message.contains("marker"), "No internal jargon")

        var empty = DraftMarkerSearchResult()
        empty.stoppedForRateLimit = true
        let none = draftCreateCheckOutcome(attempts: [ada], result: empty, time: time)
        XCTAssertTrue(none.message.hasPrefix("Slant has no matching draft: it listed no orders."))
        XCTAssertTrue(none.message.contains("rate limit"))
    }

    func testImportCheckMessageUsesCountsOnly() {
        var result = DraftMarkerSearchResult()
        result.ordersRead = 250
        XCTAssertEqual(orderImportDraftCheckMessage(confirmed: 1, stillUnconfirmed: 0, result: result),
                       "Found 1 draft that didn’t confirm: Slant did create it, and it’s marked as imported.")
        XCTAssertEqual(orderImportDraftCheckMessage(confirmed: 0, stillUnconfirmed: 2, result: result),
                       "Slant has no matching drafts for the 2 unconfirmed imports among your 250 newest orders. They probably weren’t created; if you import them again, check Show Drafts afterwards.")
        XCTAssertFalse(orderImportDraftCheckMessage(confirmed: 0, stillUnconfirmed: 1, result: result).contains("marker"))
    }

    // MARK: Import ledger

    func testLedgerKeepsMarkersForUnknownEntriesAndConfirmsThem() {
        var ledger = OrderImportLedger()
        ledger.record(.unknown, source: .etsy, sourceOrderID: "3141", marker: "m1", platformID: "p")
        ledger.record(.created(orderID: "SO-1"), source: .etsy, sourceOrderID: "2718", marker: "m2", platformID: "p")
        let key = OrderImportLedger.key(source: .etsy, sourceOrderID: "3141")
        XCTAssertEqual(ledger.unconfirmedMarkers, [key: OrderImportDraftMarker(marker: "m1", platformID: "p")])
        ledger.confirm(key: key, orderID: "SO-7")
        XCTAssertEqual(ledger.entry(source: .etsy, sourceOrderID: "3141"), .created(orderID: "SO-7"))
        XCTAssertTrue(ledger.unconfirmedMarkers.isEmpty)
        // Confirming never overwrites a created entry or invents one.
        ledger.confirm(key: OrderImportLedger.key(source: .etsy, sourceOrderID: "2718"), orderID: "SO-X")
        XCTAssertEqual(ledger.entry(source: .etsy, sourceOrderID: "2718"), .created(orderID: "SO-1"))
        ledger.confirm(key: "csv|nope", orderID: "SO-X")
        XCTAssertNil(ledger.entries["csv|nope"])
        // A later unknown without a marker drops the old one.
        ledger.record(.unknown, source: .template, sourceOrderID: "1", marker: "m3", platformID: "p")
        ledger.record(.unknown, source: .template, sourceOrderID: "1")
        XCTAssertTrue(ledger.unconfirmedMarkers.isEmpty)
    }
}
