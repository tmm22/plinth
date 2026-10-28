import XCTest
@testable import SlantStudio

/// The order watch follows the status Studio shows (`orderDisplayStatus`), so a PRINTING order whose shipping record
/// says SHIPPED (live, 29 Oct 2026) is reported as shipped once; and Show / notification clicks read changed orders
/// through a platform-filtered list when a default platform is set (live orders name no platform ID).
final class OrderWatchShippingTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_790_000_000)

    /// Shaped like the live list rows of 29 Oct 2026 (customer and address redacted; `platform` has no ID).
    private func liveOrder(_ id: String, status: Any?, fulfillment: Any? = nil, wrapped: Bool = false) -> Record {
        var order: [String: Any] = [
            "publicId": id, "createdAt": "2026-01-05T10:00:00Z", "updatedAt": "2026-01-08T10:00:00Z",
            "deliveryCost": "20.00", "printingCost": "10.00", "customer": ["details": ["name": "Ada Lovelace"]],
            "items": [["type": "PRINT", "status": "PRINTING", "price": "10.00", "currency": "USD", "quantity": 1]],
            "platform": ["name": "Shop", "url": "https://example.com/", "enabled": true]
        ]
        if let status { order["status"] = status }
        order["fulfillment"] = fulfillment ?? NSNull()
        return Record(values: wrapped ? ["order": order, "publicId": id] : order)
    }
    private func shipping(_ status: Any) -> [String: Any] {
        ["status": status, "provider": "SHIPPO", "trackingNumbers": ["1Z999"], "labelPrinted": true]
    }
    private func obs(_ id: String, _ status: String) -> OrderWatchObservation {
        OrderWatchObservation(id: id, status: status, number: id)
    }
    private func json(_ object: Any) throws -> APIResponse {
        APIResponse(data: try JSONSerialization.data(withJSONObject: object), statusCode: 200)
    }

    // MARK: Observations follow the shown status

    func testObservationsUseTheShippingRecordWhileTheOrderStatusLags() {
        let rows = [
            liveOrder("SLANT_1", status: "PRINTING", fulfillment: shipping("SHIPPED")),
            liveOrder("SLANT_2", status: "PRINTING", fulfillment: shipping(" delivered ")),
            liveOrder("SLANT_3", status: "SUBMITTED", fulfillment: shipping("SHIPPED"), wrapped: true),
            liveOrder("SLANT_4", status: "PRINTING", fulfillment: shipping("AWAITING_SHIPMENT")),
            liveOrder("SLANT_5", status: "PRINTING", fulfillment: shipping("IN_TRANSIT")),
            liveOrder("SLANT_6", status: "PRINTING"),
            liveOrder("SLANT_7", status: "DRAFT", fulfillment: shipping("SHIPPED")),
            liveOrder("SLANT_8", status: "CANCELLED", fulfillment: shipping("SHIPPED")),
            liveOrder("SLANT_9", status: "MYSTERY", fulfillment: shipping("SHIPPED")),
            liveOrder("SLANT_10", status: "PRINTING", fulfillment: shipping(7)),
            liveOrder("SLANT_11", status: "PRINTING", fulfillment: "odd"),
            liveOrder("SLANT_12", status: nil, fulfillment: shipping("SHIPPED")),
            liveOrder("SLANT_13", status: 3, fulfillment: shipping("SHIPPED")),
            liveOrder("SLANT_14", status: "SHIPPED", fulfillment: shipping("DELIVERED"))
        ]
        XCTAssertEqual(orderWatchObservations(rows), [
            obs("SLANT_1", "SHIPPED"), obs("SLANT_2", "SHIPPED"), obs("SLANT_3", "SHIPPED"), obs("SLANT_4", "PRINTING"),
            obs("SLANT_5", "PRINTING"), obs("SLANT_6", "PRINTING"), obs("SLANT_7", "DRAFT"), obs("SLANT_8", "CANCELLED"),
            obs("SLANT_9", "MYSTERY"), obs("SLANT_10", "PRINTING"), obs("SLANT_11", "PRINTING"), obs("SLANT_14", "SHIPPED")
        ])
    }

    func testBothReadsOfACheckSeeTheSameStatus() {
        let row = liveOrder("SLANT_1", status: "PRINTING", fulfillment: shipping("SHIPPED"))
        let merged = orderWatchMergedObservations(orderWatchObservations([row]), orderWatchObservations([row]))
        XCTAssertEqual(merged, [obs("SLANT_1", "SHIPPED")])
    }

    func testFirstSightOfAShippedRecordIsSilent() {
        let rows = [liveOrder("SLANT_1", status: "PRINTING", fulfillment: shipping("SHIPPED"))]
        let applied = orderWatchApplying(orderWatchObservations(rows), to: OrderWatchSnapshot(), now: t0)
        XCTAssertTrue(applied.transitions.isEmpty)
        XCTAssertTrue(orderWatchUnseenChanges(applied.snapshot).isEmpty)
        XCTAssertEqual(applied.snapshot.orders["SLANT_1"]?.status, "SHIPPED")
    }

    // MARK: The snapshot the previous build saved (29 Oct 2026)

    func testPreviousBuildsSnapshotGetsOneCatchUpShippedNotification() throws {
        // AWAITING_SHIPMENT → PRINTING was recorded as Slant's re-labelling, so the status moved and seenStatus didn't.
        let saved = """
        {"version":1,"updatedAt":1790000000,"orders":{
          "SLANT_1000000000001":{"status":"PRINTING","seenStatus":"AWAITING_SHIPMENT","lastSeen":1790000000,"changedAt":1789000000},
          "SLANT_1000000000002":{"status":"PRINTING","seenStatus":"PRINTING","lastSeen":1790000000}}}
        """
        let snapshot = try XCTUnwrap(decodeOrderWatchSnapshot(Data(saved.utf8), now: t0))
        XCTAssertTrue(orderWatchUnseenChanges(snapshot).isEmpty, "the relabel is not listed")

        let later = t0.addingTimeInterval(240)
        let rows = [liveOrder("SLANT_1000000000002", status: "PRINTING"),
                    liveOrder("SLANT_1000000000001", status: "PRINTING", fulfillment: shipping("SHIPPED"))]
        let applied = orderWatchApplying(orderWatchObservations(rows), to: snapshot, now: later)
        XCTAssertEqual(applied.transitions.map(\.to), ["SHIPPED"])
        let texts = orderWatchNotificationTexts(applied.transitions)
        XCTAssertEqual(texts.count, 1)
        XCTAssertEqual(texts.first?.title, "Order SLANT_1000000000001 has shipped")
        XCTAssertEqual(texts.first?.body, "Printing → Shipped")
        XCTAssertEqual(texts.first?.orderID, "SLANT_1000000000001")

        let changes = orderWatchUnseenChanges(applied.snapshot)
        XCTAssertEqual(changes, [OrderWatchChange(id: "SLANT_1000000000001", from: "AWAITING_SHIPMENT", to: "SHIPPED", changedAt: later)])
        XCTAssertEqual(orderWatchBadgeCount(changes), 1)
        XCTAssertEqual(orderWatchDockBadgeLabel(count: orderWatchBadgeCount(changes), showOnDock: true), "1")
        XCTAssertTrue(orderWatchChangesIncludeShipped(changes))
        XCTAssertEqual(orderWatchSummaryText(changes), "1 shipped")

        // Slant's order status catches up: SHIPPED → SHIPPED, nothing new.
        let caughtUp = orderWatchApplying(
            orderWatchObservations([liveOrder("SLANT_1000000000001", status: "SHIPPED", fulfillment: shipping("SHIPPED"))]),
            to: applied.snapshot, now: later.addingTimeInterval(240))
        XCTAssertTrue(caughtUp.transitions.isEmpty)
        XCTAssertTrue(orderWatchNotificationTexts(caughtUp.transitions).isEmpty)
        XCTAssertEqual(caughtUp.snapshot.orders["SLANT_1000000000001"]?.changedAt, later)

        // Saved as a status word only.
        let encoded = try XCTUnwrap(encodeOrderWatchSnapshot(caughtUp.snapshot))
        let text = String(decoding: encoded, as: UTF8.self)
        XCTAssertFalse(text.contains("1Z999"))
        XCTAssertFalse(text.contains("SHIPPO"))
        XCTAssertFalse(text.contains("Ada"))
    }

    // MARK: Re-labelling never swallows a shipment

    func testShippedFromAProductionStatusIsNeverARelabel() {
        for from in ["PRINTING", "SUBMITTED", "AWAITING_SHIPMENT", "PAID", "QUEUED", "PROCESSING", "COMPLETED"] {
            XCTAssertFalse(orderWatchChangeIsSlantRelabel(from: from, to: "SHIPPED"), from)
            XCTAssertTrue(orderWatchChangeIsReported(from: from, to: "SHIPPED"), from)
            XCTAssertTrue(orderWatchShouldNotify(OrderWatchTransition(id: "A", number: "A", from: from, to: "SHIPPED")), from)
            XCTAssertTrue(orderWatchShouldNotify(OrderWatchTransition(id: "A", number: "A", from: from, to: "DELIVERED")), from)
        }
    }

    /// A DELIVERED shipping record (never seen live) is observed as Shipped, so the status never goes backwards when
    /// Slant's order status catches up to SHIPPED: one "has shipped", then nothing.
    func testDeliveredRecordReadsAsShippedAndTheCatchUpIsNoChange() {
        var snapshot = orderWatchApplying([obs("A", "PRINTING")], to: OrderWatchSnapshot(), now: t0).snapshot
        let t1 = t0.addingTimeInterval(240), t2 = t1.addingTimeInterval(240)
        let delivered = orderWatchApplying(orderWatchObservations([liveOrder("A", status: "PRINTING", fulfillment: shipping("DELIVERED"))]),
                                           to: snapshot, now: t1)
        XCTAssertEqual(delivered.transitions.map(\.to), ["SHIPPED"])
        XCTAssertEqual(orderWatchNotificationTexts(delivered.transitions).map(\.title), ["Order A has shipped"])
        snapshot = orderWatchAcknowledging(delivered.snapshot)
        let caughtUp = orderWatchApplying(orderWatchObservations([liveOrder("A", status: "SHIPPED", fulfillment: shipping("DELIVERED"))]),
                                          to: snapshot, now: t2)
        XCTAssertTrue(caughtUp.transitions.isEmpty)
        XCTAssertTrue(orderWatchNotificationTexts(caughtUp.transitions).isEmpty)
        XCTAssertTrue(orderWatchUnseenChanges(caughtUp.snapshot).isEmpty)
        XCTAssertEqual(caughtUp.snapshot.orders["A"]?.status, "SHIPPED")
        XCTAssertEqual(caughtUp.snapshot.orders["A"]?.changedAt, t1)
    }

    // MARK: A shipping record withdrawn

    func testWithdrawnShippingRecordIsListedButNeverNotifiedOrBadged() {
        var snapshot = orderWatchApplying([obs("A", "PRINTING")], to: OrderWatchSnapshot(), now: t0).snapshot
        let t1 = t0.addingTimeInterval(240), t2 = t1.addingTimeInterval(240)
        snapshot = orderWatchApplying(orderWatchObservations([liveOrder("A", status: "PRINTING", fulfillment: shipping("SHIPPED"))]),
                                      to: snapshot, now: t1).snapshot
        snapshot = orderWatchAcknowledging(snapshot)
        let withdrawn = orderWatchApplying(orderWatchObservations([liveOrder("A", status: "PRINTING")]), to: snapshot, now: t2)
        XCTAssertEqual(withdrawn.transitions.map(\.to), ["PRINTING"])
        XCTAssertTrue(orderWatchNotificationTexts(withdrawn.transitions).isEmpty)
        let changes = orderWatchUnseenChanges(withdrawn.snapshot)
        XCTAssertEqual(changes.map(\.to), ["PRINTING"])
        XCTAssertEqual(orderWatchBadgeCount(changes), 0)
        XCTAssertFalse(orderWatchChangesIncludeShipped(changes))
    }

    func testShippingRecordThatComesAndGoesUnseenLeavesNothing() {
        var snapshot = orderWatchApplying([obs("A", "PRINTING")], to: OrderWatchSnapshot(), now: t0).snapshot
        snapshot = orderWatchApplying(orderWatchObservations([liveOrder("A", status: "PRINTING", fulfillment: shipping("SHIPPED"))]),
                                      to: snapshot, now: t0.addingTimeInterval(240)).snapshot
        XCTAssertEqual(orderWatchBadgeCount(orderWatchUnseenChanges(snapshot)), 1)
        snapshot = orderWatchApplying(orderWatchObservations([liveOrder("A", status: "PRINTING", fulfillment: shipping("AWAITING_SHIPMENT"))]),
                                      to: snapshot, now: t0.addingTimeInterval(480)).snapshot
        XCTAssertTrue(orderWatchUnseenChanges(snapshot).isEmpty)
    }

    // MARK: Reads for Show and notification clicks

    func testFetchFiltersByTheDefaultPlatform() {
        let fetch = orderWatchFetch(id: "SLANT_1000000000001", platformID: " plat-1 ")
        XCTAssertEqual(fetch.path, "/orders")
        XCTAssertTrue(fetch.listed)
        XCTAssertEqual(fetch.query, ["publicId": "SLANT_1000000000001", "platformId": "plat-1", "page": "1", "limit": String(listPageSize)])
    }

    func testFetchWithoutAPlatformReadsByID() {
        let fetch = orderWatchFetch(id: "SLANT_1/x?y", platformID: "  ")
        XCTAssertEqual(fetch.path, "/orders/SLANT_1%2Fx%3Fy")
        XCTAssertFalse(fetch.listed)
        XCTAssertTrue(fetch.query.isEmpty)
    }

    func testListedReplyGivesOnlyTheExactOrderOnThePlatform() throws {
        let fetch = orderWatchFetch(id: "SLANT_1", platformID: "plat-1")
        let row: [String: Any] = ["publicId": "SLANT_1", "status": "PRINTING", "platform": ["name": "Shop"]]
        let found = orderWatchFetchedRecord(try json(["success": true, "data": [row], "pagination": ["count": 1]]),
                                            fetch: fetch, id: "SLANT_1", platformID: "plat-1")
        XCTAssertEqual(found?.id, "SLANT_1")
        // Another platform's order: Slant answers with an empty list.
        XCTAssertNil(orderWatchFetchedRecord(try json(["success": true, "data": [], "pagination": ["count": 0]]),
                                             fetch: fetch, id: "SLANT_1", platformID: "plat-1"))
        // A reply that ignored publicId (the newest orders) never stands in for the order.
        let others: [[String: Any]] = [["publicId": "SLANT_2", "status": "DRAFT"], ["publicId": "slant_1", "status": "DRAFT"]]
        XCTAssertNil(orderWatchFetchedRecord(try json(["success": true, "data": others]), fetch: fetch, id: "SLANT_1", platformID: "plat-1"))
        // An order that does name another platform is still refused.
        var foreign = row; foreign["platformId"] = "plat-2"
        XCTAssertNil(orderWatchFetchedRecord(try json(["success": true, "data": [foreign]]), fetch: fetch, id: "SLANT_1", platformID: "plat-1"))
        // Unreadable reply.
        XCTAssertNil(orderWatchFetchedRecord(APIResponse(data: Data("nope".utf8), statusCode: 200), fetch: fetch, id: "SLANT_1",
                                             platformID: "plat-1"))
    }

    func testByIDReplyIsReadAsBefore() throws {
        let fetch = orderWatchFetch(id: "SLANT_1", platformID: "")
        let reply: [String: Any] = ["success": true, "message": "Order Retrieved",
                                    "data": ["order": ["publicId": "SLANT_1", "status": "PRINTING"]]]
        let found = orderWatchFetchedRecord(try json(reply), fetch: fetch, id: "SLANT_1", platformID: "")
        XCTAssertEqual(found?.id, "SLANT_1")
        XCTAssertEqual(found?.values["status"] as? String, "PRINTING")
        XCTAssertNil(orderWatchFetchedRecord(try json(reply), fetch: fetch, id: "SLANT_2", platformID: ""))
    }
}
