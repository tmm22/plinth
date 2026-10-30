import XCTest
@testable import Plinth

final class OrderDisplayStatusTests: XCTestCase {
    private func order(_ status: Any?, fulfillment: Any? = nil) -> [String: Any] {
        var order: [String: Any] = [:]
        if let status { order["status"] = status }
        if let fulfillment { order["fulfillment"] = fulfillment }
        return order
    }

    /// The live shape seen 29 Oct 2026: order PRINTING, shipping record SHIPPED with tracking.
    func testPrintingOrderWhoseShippingRecordSaysShippedShowsShipped() {
        let live = order("PRINTING", fulfillment: ["status": "SHIPPED", "provider": "SHIPPO", "trackingNumbers": ["X"], "labelPrinted": true])
        XCTAssertEqual(orderDisplayStatus(live), "SHIPPED")
        XCTAssertTrue(orderStatusLagsShippingRecord(live))
        XCTAssertEqual(orderDisplayStatus(order("submitted", fulfillment: ["status": " delivered "])), "SHIPPED", "a DELIVERED record reads as Shipped")
    }

    func testEverythingElseKeepsSlantsOrderStatus() {
        let cases: [[String: Any]] = [
            order("PRINTING"),
            order("PRINTING", fulfillment: NSNull()),
            order("PRINTING", fulfillment: ["trackingNumbers": ["X"]]),
            order("PRINTING", fulfillment: ["status": "AWAITING_SHIPMENT", "labelPrinted": true]),
            order("PRINTING", fulfillment: ["status": "RETURNED"]),
            order("PRINTING", fulfillment: ["status": 3]),
            order("DRAFT", fulfillment: ["status": "SHIPPED"]),
            order("CANCELLED", fulfillment: ["status": "SHIPPED"]),
            order("CANCELED", fulfillment: ["status": "DELIVERED"]),
            order("PAYMENT_ERROR", fulfillment: ["status": "SHIPPED"]),
            order("ON_HOLD", fulfillment: ["status": "SHIPPED"]),
            order(nil, fulfillment: ["status": "SHIPPED"]),
            order("SHIPPED", fulfillment: ["status": "DELIVERED"]),
        ]
        for value in cases {
            XCTAssertEqual(orderDisplayStatus(value), (value["status"] as? String) ?? "", "\(value)")
            XCTAssertFalse(orderStatusLagsShippingRecord(value), "\(value)")
        }
    }

    func testFulfillmentStatusIsTrimmedAndUpperCased() {
        XCTAssertEqual(orderFulfillmentStatus(order("PRINTING", fulfillment: ["status": " shipped\n"])), "SHIPPED")
        XCTAssertNil(orderFulfillmentStatus(order("PRINTING", fulfillment: ["status": "  "])))
        XCTAssertNil(orderFulfillmentStatus(order("PRINTING", fulfillment: "SHIPPED")))
    }
}
