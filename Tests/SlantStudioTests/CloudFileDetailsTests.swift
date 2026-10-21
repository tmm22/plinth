import XCTest
@testable import SlantStudio

final class CloudFileDetailsTests: XCTestCase {
    func testProductionNotesShowOnlyWhenPresent() {
        XCTAssertEqual(slantProductionNotes(Record(values: ["notes": "  Wall too thin near the clip.\n"])), "Wall too thin near the clip.")
        XCTAssertNil(slantProductionNotes(Record(values: [:])))
        XCTAssertNil(slantProductionNotes(Record(values: ["notes": NSNull()])))
        XCTAssertNil(slantProductionNotes(Record(values: ["notes": "   "])))
        XCTAssertNil(slantProductionNotes(Record(values: ["notes": 12])))
    }

    func testSurfaceAreaAndSupportVolumeUseSpecUnits() {
        let entries = usableMetricEntries(["x": 20, "surfaceArea": 1500.5, "supportVolumeEstimate": 2.25, "volume": NSNull()])
        XCTAssertEqual(entries.map(\.0), ["x", "surfaceArea", "supportVolumeEstimate"])
        XCTAssertEqual(entries[1].1, "Surface area")
        XCTAssertEqual(entries[1].2, "1500.5 mm²")
        XCTAssertEqual(entries[2].1, "Support volume (est.)")
        XCTAssertEqual(entries[2].2, "2.25 cm³")
        // Slant's own `units` map wins over the defaults.
        let custom = usableMetricEntries(["surfaceArea": 15, "units": ["surfaceArea": "cm²"]])
        XCTAssertEqual(custom.first?.2, "15 cm²")
    }

    func testFileDatesParseISO8601AndHideUnchangedUpdates() {
        let format: (Date) -> String = { String(Int($0.timeIntervalSince1970)) }
        let same = Record(values: ["createdAt": "2026-01-02T03:04:05.000Z", "updatedAt": "2026-01-02T03:04:05Z"])
        XCTAssertEqual(cloudFileDateRows(same, formatter: format).map(\.0), ["Uploaded"])
        let changed = Record(values: ["createdAt": "2026-01-02T03:04:05Z", "updatedAt": "2026-01-03T03:04:05.250Z"])
        let rows = cloudFileDateRows(changed, formatter: format)
        XCTAssertEqual(rows.map(\.0), ["Uploaded", "Updated"])
        XCTAssertEqual(rows[1].1, String(Int(ISO8601DateFormatter().date(from: "2026-01-03T03:04:05Z")!.timeIntervalSince1970)))
        XCTAssertTrue(cloudFileDateRows(Record(values: ["createdAt": "yesterday", "updatedAt": NSNull()])).isEmpty)
        XCTAssertEqual(cloudFileDateRows(Record(values: ["updatedAt": "2026-01-03T03:04:05Z"]), formatter: format).map(\.0), ["Updated"])
    }
}
