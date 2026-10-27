import XCTest
@testable import SlantStudio

/// Round 13 (Models and mesh tools): copy names, the Auto-improve triangle limit, wall-thickness wording, sheet titles
/// and Catalog display helpers.
final class Round13ModelsTests: XCTestCase {

    // MARK: Copy names

    func testNewCopiesUseTheParenthesisedSuffix() {
        XCTAssertEqual(autoImproveCopyName("Bracket"), "Bracket (auto-improved)")
        XCTAssertEqual(autoImproveCopyName("Owl (print-ready)"), "Owl (print-ready) (auto-improved)")
        // Made safe for a file name, as the mesh tools' copies are.
        XCTAssertEqual(autoImproveCopyName("a/b:c"), "a-b-c (auto-improved)")
        XCTAssertEqual(autoImproveCopyName("  "), "Model (auto-improved)")
        XCTAssertLessThanOrEqual(autoImproveCopyName(String(repeating: "x", count: 400)).utf8.count, 220)
        // The mesh tools' names are unchanged by the shared helper.
        XCTAssertEqual(meshToolCopyName("Bracket", kind: .repair), "Bracket (repaired)")
        XCTAssertEqual(meshToolCopyName("Bracket", kind: .simplify(target: 100)), "Bracket (simplified)")
    }

    func testReinforceCopyNames() {
        XCTAssertEqual(reinforcementCopyName("Bracket", kind: .internalWalls), "Bracket (internal walls)")
        XCTAssertEqual(reinforcementCopyName("Bracket", kind: .teardrop), "Bracket (teardrop holes)")
        XCTAssertEqual(reinforcementCopyName("Bracket", kind: .thicken), "Bracket (matched walls)")
        XCTAssertEqual(reinforcementCopyName("Bracket", kind: .split, part: 1), "Bracket (part 1)")
        XCTAssertEqual(reinforcementCopyName("Bracket", kind: .split, part: 2), "Bracket (part 2)")
        XCTAssertEqual(reinforcementCopyName("a/b", kind: .bridge), "a-b (bridging)")
    }

    // MARK: Triangle limit

    func testAutoImproveIsBlockedOverTheTriangleLimit() throws {
        XCTAssertNil(autoImproveTriangleLimitProblem(triangles: nil), "Unknown until the preview loads; the run still refuses")
        XCTAssertNil(autoImproveTriangleLimitProblem(triangles: meshToolsReinforceTriangleLimit))
        let problem = try XCTUnwrap(autoImproveTriangleLimitProblem(triangles: 37_342))
        XCTAssertTrue(problem.contains("37,342"), problem)
        XCTAssertTrue(problem.contains("Simplify & Save Copy"), problem)
        XCTAssertTrue(autoImproveTooManyTrianglesCaption.contains("20,000"))
    }

    func testReinforceLimitPointsToStudiosOwnSimplify() {
        let message = reinforceTooManyTrianglesMessage(37_342)
        XCTAssertTrue(message.contains("Simplify & Save Copy"), message)
        XCTAssertTrue(message.contains("37,342"), message)
        XCTAssertFalse(message.contains("CAD"), message)
    }

    // MARK: Wall thickness

    private func report(under1: Double, under2: Double) -> WallThicknessReport {
        WallThicknessReport(sampleCount: 1000, measuredCount: 1000, surfaceAreaMM2: 100, thinnestMM: 0.8, percentile5MM: 0.9,
                            medianMM: 3, fractionUnder1MM: under1, fractionUnder2MM: under2, bands: [], thinSpots: [],
                            smallFeatures: [])
    }

    func testWallThicknessLineNamesTheSurfaceOnce() {
        XCTAssertEqual(wallThicknessSummary(report(under1: 0.004, under2: 0.09)).line,
                       "Wall thickness: 9% of the surface under 2 mm, including less than 1% under 1 mm")
        XCTAssertEqual(wallThicknessSummary(report(under1: 0.03, under2: 0.12)).line,
                       "Wall thickness: 12% of the surface under 2 mm, including 3% under 1 mm")
        XCTAssertEqual(wallThicknessSummary(report(under1: 0, under2: 0.004)).line,
                       "Wall thickness: less than 1% of the surface under 2 mm")
        XCTAssertEqual(surfacePercentLabel(0), "0%")
        XCTAssertEqual(surfacePercentLabel(0.004), "less than 1%")
        XCTAssertEqual(surfacePercentLabel(0.5), "50%")
        // The breakdown's own labels are unchanged.
        XCTAssertEqual(percentLabel(0.004), "under 1%")
    }

    // MARK: Sheet titles

    func testSizeAndBaseSheetTitlesAreSentenceCase() {
        XCTAssertEqual(MeshFitTool.scale.sheetTitle, "Scale to size")
        XCTAssertEqual(MeshFitTool.flatBase.sheetTitle, "Add flat base")
        XCTAssertEqual(MeshFitTool.plinth.sheetTitle, "Add plinth")
        XCTAssertEqual(MeshFitTool.fitCoupon.sheetTitle, "Make fit coupon")
        // The buttons keep Title Case.
        XCTAssertEqual(MeshFitTool.flatBase.title, "Add Flat Base")
    }

    // MARK: Catalog

    func testCatalogCardsSortByTitle() {
        let records = [
            Record(values: ["id": "1", "name": "PLA PURPLE"]),
            Record(values: ["id": "2", "name": "PLA BLACK"]),
            Record(values: ["id": "3", "name": "PETG WHITE"]),
            Record(values: ["id": "4", "name": "PLA 10"]),
            Record(values: ["id": "5", "name": "PLA 2"]),
            Record(values: ["id": "6", "name": "PLA BLACK"]),
        ]
        XCTAssertEqual(catalogRecordsSortedByTitle(records, kind: .materials).map(\.id), ["3", "5", "4", "2", "6", "1"])
        let components = [Record(values: ["id": "b", "name": "magnet"]), Record(values: ["id": "a", "name": "Bolt"])]
        XCTAssertEqual(catalogRecordsSortedByTitle(components, kind: .components).map(\.id), ["a", "b"])
    }

    func testCatalogColourIsCapitalised() {
        XCTAssertEqual(catalogColourDisplay("black"), "Black")
        XCTAssertEqual(catalogColourDisplay(" light grey "), "Light Grey")
        XCTAssertEqual(catalogColourDisplay("BLACK"), "Black")
        XCTAssertEqual(catalogColourDisplay("PLA"), "PLA")
        XCTAssertEqual(catalogColourDisplay("Light grey"), "Light grey", "Mixed case is kept as sent")
        XCTAssertEqual(catalogColourDisplay(""), "")
    }

    func testMaterialUseCaptionNamesTheModel() {
        XCTAssertTrue(catalogMaterialUseCaption.contains("print configuration"))
    }

    func testComponentsAndStationeryLoadOnceWhenFirstShown() {
        func should(_ kind: Destination, loaded: Bool = false, hasKey: Bool = true, busy: Bool = false, tried: Bool = false,
                    remaining: Int? = nil) -> Bool {
            catalogShouldLoadOnShow(kind, loaded: loaded, hasKey: hasKey, busy: busy, alreadyTried: tried, rateLimitRemaining: remaining)
        }
        XCTAssertTrue(should(.components))
        XCTAssertTrue(should(.stationery, remaining: 50))
        XCTAssertFalse(should(.materials), "Materials have their own stale-refresh path")
        XCTAssertFalse(should(.platforms))
        XCTAssertFalse(should(.components, loaded: true))
        XCTAssertFalse(should(.components, hasKey: false))
        XCTAssertFalse(should(.components, busy: true))
        XCTAssertFalse(should(.components, tried: true), "Tried once a session; the Load button stays")
        XCTAssertFalse(should(.stationery, remaining: catalogLoadOnShowReserve))
        XCTAssertTrue(should(.stationery, remaining: catalogLoadOnShowReserve + 1))
    }
}
