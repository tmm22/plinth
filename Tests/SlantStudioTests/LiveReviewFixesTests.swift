import XCTest
import SwiftUI
@testable import SlantStudio

/// Fixes from live testing against Slant on 23 Oct 2026 (Models and Settings).
final class LiveReviewFixesTests: XCTestCase {
    // Headers observed on GET /v2/api/filaments: Date 08:10:25 GMT, X-RateLimit-Reset 1800000685873 (08:11:25.873Z).
    private let liveNow = Date(timeIntervalSince1970: 1_800_000_625)
    private let liveReset = "1800000685873"

    // MARK: X-RateLimit-Reset

    func testResetHeaderIsReadAsEpochMilliseconds() throws {
        let reset = try XCTUnwrap(rateLimitResetDate(liveReset, now: liveNow))
        XCTAssertEqual(reset.timeIntervalSince1970, 1_800_000_685.873, accuracy: 0.0005)
        XCTAssertEqual(reset.timeIntervalSince(liveNow), 60.873, accuracy: 0.0005)
        let info = rateLimitInfo(from: ["X-RateLimit-Limit": "100", "X-RateLimit-Remaining": "99",
                                        "X-RateLimit-Reset": liveReset, "X-RateLimit-Role": "free"], now: liveNow)
        XCTAssertEqual(info.reset, reset)
        XCTAssertEqual(info.limit, 100)
        XCTAssertEqual(info.remaining, 99)
        XCTAssertEqual(info.role, "free")
    }

    func testResetHeaderToleratesSecondsAndRelativeValues() {
        XCTAssertEqual(rateLimitResetDate("1800000685", now: liveNow), Date(timeIntervalSince1970: 1_800_000_685))
        XCTAssertEqual(rateLimitResetDate(" 1800000685.5 ", now: liveNow), Date(timeIntervalSince1970: 1_800_000_685.5))
        XCTAssertEqual(rateLimitResetDate("45", now: liveNow), liveNow.addingTimeInterval(45), "small value: seconds from now")
        XCTAssertEqual(rateLimitResetDate("0", now: liveNow), liveNow)
        // A past reset is still a date; callers only wait for one in the future.
        XCTAssertEqual(rateLimitResetDate("1700000000000", now: liveNow), Date(timeIntervalSince1970: 1_700_000_000))
    }

    func testResetHeaderRejectsGarbage() {
        for raw: String? in [nil, "", "  ", "soon", "-5", "-1800000685873", "nan", "NaN", "inf", "1e400", "12abc",
                             "1800000685873000", // microseconds: would be ~58,000 years away
                             "200000",          // relative but more than a day away
                             "60000"] {         // relative milliseconds would be 16.7 h: refused, not trusted
            XCTAssertNil(rateLimitResetDate(raw, now: liveNow), String(describing: raw))
        }
        XCTAssertNil(rateLimitInfo(from: ["X-RateLimit-Reset": "garbage"], now: liveNow).reset)
        XCTAssertFalse(rateLimitInfo(from: ["X-RateLimit-Reset": "garbage"], now: liveNow).hasValues)
    }

    func testTooManyRequestsCopyUsesTheRealWait() {
        XCTAssertEqual(rateLimitUserMessage(retryAfter: nil, rateLimitReset: liveReset, now: liveNow),
                       "Too many requests. Try again in about 61 seconds.")
        XCTAssertEqual(rateLimitUserMessage(retryAfter: nil, rateLimitReset: "1800000565873", now: liveNow),
                       "Too many requests. Wait a moment, then try again.", "a past reset gives no countdown")
        XCTAssertEqual(rateLimitUserMessage(retryAfter: nil, rateLimitReset: "garbage", now: liveNow),
                       "Too many requests. Wait a moment, then try again.")
        XCTAssertEqual(rateLimitResetWaitCopy(secondsFromNow: 0.4), "Try again in about 1 second.")
        XCTAssertEqual(rateLimitResetWaitCopy(secondsFromNow: 600), "Try again in about 10 minutes.")
    }

    func testComparisonAndImportWaitForTheLiveResetAndStayBounded() {
        let until = comparisonRateLimitedUntil(retryAfter: nil, rateLimitReset: liveReset, now: liveNow)
        XCTAssertEqual(until.timeIntervalSince(liveNow), 60.873, accuracy: 0.001)
        // Import waits for it (under its 5-minute cap) rather than stopping.
        XCTAssertEqual(orderImportPacing(lastRequestStart: nil, rateLimit: nil, rateLimitedUntil: until, now: liveNow), .wait(until.timeIntervalSince(liveNow)))
        // A low allowance from live headers: Compare stops with copy naming about a minute; Import waits.
        let low = rateLimitInfo(from: ["X-RateLimit-Limit": "100", "X-RateLimit-Remaining": "4", "X-RateLimit-Reset": liveReset], now: liveNow)
        guard case .stop(let message) = comparisonPacing(rateLimit: low, observedAt: liveNow, now: liveNow) else { return XCTFail("should stop") }
        XCTAssertTrue(message.contains("about 61 seconds"), message)
        guard case .wait(let wait) = orderImportPacing(lastRequestStart: nil, rateLimit: low, rateLimitedUntil: nil, now: liveNow) else {
            return XCTFail("a one-minute reset should be waited for")
        }
        XCTAssertEqual(wait, 60.873, accuracy: 0.001)
        // A reset in seconds an hour or more away is still capped at an hour after a 429.
        let far = comparisonRateLimitedUntil(retryAfter: nil, rateLimitReset: String(Int(liveNow.timeIntervalSince1970) + 7200), now: liveNow)
        XCTAssertEqual(far, liveNow.addingTimeInterval(3600))
        guard case .stop = orderImportPacing(lastRequestStart: nil, rateLimit: nil, rateLimitedUntil: far, now: liveNow) else {
            return XCTFail("waits over 5 minutes stop the import")
        }
    }

    // MARK: Model analysis tiles

    func testMetricUnitsUseSuperscripts() {
        let metrics: [String: Any] = ["volume": 165.19, "supportVolumeEstimate": 54.28, "surfaceArea": 12,
                                      "units": ["volume": "cm3", "supportVolumeEstimate": "cm3", "surfaceArea": "mm2", "x": "mm"]]
        XCTAssertEqual(metricUnit("volume", metrics), "cm³")
        XCTAssertEqual(metricUnit("supportVolumeEstimate", metrics), "cm³")
        XCTAssertEqual(metricUnit("surfaceArea", metrics), "mm²")
        XCTAssertEqual(metricUnit("x", metrics), "mm")
        XCTAssertEqual(metricUnit("volume", ["units": ["volume": "  "]]), "cm³", "blank unit falls back")
        XCTAssertEqual(metricUnit("bodyCount", [:]), "")
        XCTAssertEqual(displayUnit("CM3"), "cm³")
        XCTAssertEqual(displayUnit("in3"), "in³")
        XCTAssertEqual(displayUnit("g"), "g")
        let tiles = usableMetricEntries(metrics)
        XCTAssertEqual(tiles.first { $0.0 == "volume" }?.2, "165.19 cm³")
        XCTAssertEqual(tiles.first { $0.0 == "supportVolumeEstimate" }?.2, "54.28 cm³")
    }

    func testPrintTimeShowsHoursAndMinutes() {
        XCTAssertEqual(formattedPrintMinutes(402), "6 h 42 min")
        XCTAssertEqual(formattedPrintMinutes(45), "45 min")
        XCTAssertEqual(formattedPrintMinutes(59.6), "1 h")
        XCTAssertEqual(formattedPrintMinutes(120), "2 h")
        XCTAssertEqual(formattedPrintMinutes(0), "0 min")
        XCTAssertEqual(formattedPrintMinutes(0.3), "Under 1 min")
        XCTAssertEqual(formattedPrintMinutes("90"), "1 h 30 min")
        for bad: Any? in [nil, -5, Double.nan, Double.infinity, "soon", true, NSNull()] {
            XCTAssertNil(formattedPrintMinutes(bad), String(describing: bad))
        }
        XCTAssertEqual(usableMetricEntries(["printTimeEstimate": 402, "units": ["printTimeEstimate": "min"]]).map(\.2), ["6 h 42 min"])
        XCTAssertEqual(usableMetricEntries(["printTimeEstimate": 402]).map(\.2), ["6 h 42 min"], "documented as minutes")
        XCTAssertEqual(usableMetricEntries(["printTimeEstimate": 6.7, "units": ["printTimeEstimate": "h"]]).map(\.2), ["6.7 h"],
                       "another unit is shown as given")
        XCTAssertEqual(usableMetricEntries(["printTimeEstimate": "pending"]).map(\.2), ["pending min"])
    }

    // MARK: Copy and small helpers

    func testNeedsEstimateCopyAssumesAMaterialIsChosen() {
        // A missing material is reported by the bar before this text is used.
        XCTAssertEqual(nextStepStatusText(.needsEstimate), "Get an estimate for this material and quantity.")
        XCTAssertFalse(nextStepStatusText(.needsEstimate).contains("Choose"))
    }

    func testPlatformDetailHidesUseAsDefaultForTheDefault() {
        XCTAssertFalse(platformDetailOffersUseAsDefault(platformID: "p1", defaultPlatformID: "p1"))
        XCTAssertTrue(platformDetailOffersUseAsDefault(platformID: "p2", defaultPlatformID: "p1"))
        XCTAssertTrue(platformDetailOffersUseAsDefault(platformID: "p2", defaultPlatformID: ""))
    }

    func testDisclosureAccessibilityState() {
        XCTAssertEqual(disclosureAccessibilityValue(isExpanded: true), "Expanded")
        XCTAssertEqual(disclosureAccessibilityValue(isExpanded: false), "Collapsed")
        XCTAssertNotEqual(disclosureAccessibilityHint(isExpanded: true), disclosureAccessibilityHint(isExpanded: false))
    }

    func testBadgeSwitchesStyleOnlyOnProminentBackgrounds() {
        XCTAssertTrue(studioBadgeUsesSelectedStyle(.increased))
        XCTAssertFalse(studioBadgeUsesSelectedStyle(.standard))
    }

    func testBlockedReasonsDontNameAWindow() {
        // The open sheet may be in Settings itself (platform details), not the main window.
        XCTAssertEqual(accountKeyChangeBlockedReason(busy: false, modalUIShown: true), "Close the open sheet, alert or dialog first.")
        XCTAssertEqual(developerToolsToggleBlockedReason(busy: false, modalUIShown: true), "Close the open sheet, alert or dialog first.")
    }
}
