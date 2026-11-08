import XCTest
@testable import Plinth

/// Findings of the 9 Nov 2026 Slant API audit.
final class SlantAPIAuditTests: XCTestCase {
    func testABlankReloadedStatusNeverLiftsTheLock() {
        for action in [OutcomeAction.pay, .cancel] {
            let context = UnknownOutcomeContext(action: action, reviewedStatus: action == .pay ? "DRAFT" : "SUBMITTED")
            for blank in ["", " ", "  ", "\n", " \t "] {
                XCTAssertFalse(unknownOutcomeResolvedByReload(context: context, reloadedStatus: blank), "\(action) '\(blank)'")
            }
        }
        // Real outcomes still lift it, with or without spacing.
        XCTAssertTrue(unknownOutcomeResolvedByReload(context: UnknownOutcomeContext(action: .pay, reviewedStatus: "DRAFT"),
                                                     reloadedStatus: " submitted "))
        XCTAssertFalse(unknownOutcomeResolvedByReload(context: UnknownOutcomeContext(action: .pay, reviewedStatus: "DRAFT"),
                                                      reloadedStatus: " draft "))
        XCTAssertTrue(unknownOutcomeResolvedByReload(context: UnknownOutcomeContext(action: .cancel, reviewedStatus: "SUBMITTED"),
                                                     reloadedStatus: "CANCELLED"))
    }

    func testTrackingLinksOpenOnlyOverHTTPSToANamedHost() {
        XCTAssertNotNil(orderTrackingLinkURL("https://tools.usps.com/go/TrackConfirmAction?tLabels=9400"))
        XCTAssertNotNil(orderTrackingLinkURL("  HTTPS://example.com/t  "))
        for bad in ["http://example.com/t", "javascript:alert(1)", "file:///etc/passwd", "https://", "https:///path",
                    "mailto:a@b.example", "example.com/t", ""] {
            XCTAssertNil(orderTrackingLinkURL(bad), bad)
        }
    }

    func testANonHTTPSTrackingLinkIsShownAsTextAndAGenericURLIsNotATrackingLink() {
        XCTAssertNil(trackingFacts(["url": "https://label.example/label.pdf"]).first { $0.0 == "Tracking link" })
        XCTAssertEqual(trackingFacts(["trackingUrl": "http://t.example/1"]).first { $0.0 == "Tracking link" }?.1,
                       "http://t.example/1", "facts keep Slant's value unchanged for copies")
        let order: [String: Any] = ["status": "SHIPPED", "fulfillment": ["trackingUrl": "http://t.example/1"]]
        let row = orderTrackingDisplayRows(order).first { $0.label == "Tracking link" }
        XCTAssertEqual(row?.kind, .fact)
        let secure: [String: Any] = ["status": "SHIPPED", "fulfillment": ["trackingUrl": "https://t.example/1"]]
        XCTAssertEqual(orderTrackingDisplayRows(secure).first { $0.label == "Tracking link" }?.kind, .link)
    }

    func testPlatformIDsMatchInAnyCase() {
        let order: [String: Any] = ["customer": ["platformId": "ABCDEF12-3456-7890-ABCD-EF1234567890"]]
        XCTAssertEqual(orderPlatformMatch(order, platformID: "abcdef12-3456-7890-abcd-ef1234567890"), true)
        XCTAssertEqual(orderPlatformMatch(order, platformID: "abcdef12-3456-7890-abcd-ef1234567891"), false)
        XCTAssertNil(orderPlatformMatch(["customer": [:] as [String: Any]], platformID: "x"))
    }

    func testSnakeCaseSellerKeysCountAsPlinthsOwnKeys() {
        XCTAssertTrue(orderMetadataHasKey(["studio_draft_id": "mine"], studioDraftMarkerKey))
        XCTAssertTrue(orderMetadataHasKey(["StudioDraftId": "mine"], studioDraftMarkerKey))
        XCTAssertTrue(orderMetadataHasKey(["reprint_of": "1"], orderReprintOfKey))
        XCTAssertFalse(orderMetadataHasKey(["orderRef": "1"], studioDraftMarkerKey))

        let seller: [String: Any] = ["studio_draft_id": "mine"]
        XCTAssertEqual(orderMetadataAddingDraftMarker(seller, marker: "abc") as NSDictionary, seller as NSDictionary)
        let reprintSeller: [String: Any] = ["reprint_of": "theirs"]
        XCTAssertEqual(orderMetadataAddingReprintOf(reprintSeller, original: "SLANT_1") as NSDictionary,
                       reprintSeller as NSDictionary)
        let note = orderReprintLinkNote(original: "SLANT_1", sellerMetadata: reprintSeller)
        XCTAssertTrue(note?.contains("“reprint_of”") == true, note ?? "nil")

        // Ordinary metadata still gets both.
        let added = orderMetadataAddingReprintOf(orderMetadataAddingDraftMarker(["orderRef": "1"], marker: "abc"), original: "SLANT_1")
        XCTAssertEqual(added[studioDraftMarkerKey] as? String, "abc")
        XCTAssertEqual(added[orderReprintOfKey] as? String, "SLANT_1")
    }
}

final class SlantAPIAuditReviewTests: XCTestCase {
    func testABlankRecordedCancelStatusNeverLiftsTheLock() {
        var locks = OrderOutcomeLocks()
        locks.mark("SLANT_1", action: .cancel, reviewedStatus: "  ")
        XCTAssertFalse(unknownOutcomeResolvedByReload(context: locks.contexts["SLANT_1"], reloadedStatus: "CANCELLED"))
        XCTAssertFalse(unknownOutcomeResolvedByReload(context: UnknownOutcomeContext(action: .cancel, reviewedStatus: " "),
                                                      reloadedStatus: "CANCELLED"))
    }

    func testANonHTTPSTrackingLinkSaysWhyItIsNotOpened() {
        let order: [String: Any] = ["status": "SHIPPED", "fulfillment": ["trackingUrl": "http://t.example/1"]]
        XCTAssertEqual(orderTrackingDisplayRows(order).first { $0.label == "Tracking link" }?.help, orderTrackingLinkNotOpenedHelp)
    }

    func testDuplicatePlatformSeedMatchesInAnyCase() {
        let seed = orderComposerPlatformSeed(copied: "ABCDEF12-0000-0000-0000-000000000001", current: "",
                                             loadedPlatformIDs: ["abcdef12-0000-0000-0000-000000000001"])
        XCTAssertEqual(seed.platformID, "abcdef12-0000-0000-0000-000000000001")
        XCTAssertFalse(seed.notCopied)
        let same = orderComposerPlatformSeed(copied: "ABC", current: "abc", loadedPlatformIDs: [])
        XCTAssertFalse(same.notCopied)
    }
}
