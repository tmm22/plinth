import XCTest
@testable import SlantStudio

final class ModelsRound5FixesTests: XCTestCase {
    private let nonCommercial = ModelSourceDetails(designer: "Maker", licence: "CC BY-NC-SA 4.0")
    private let noDerivatives = ModelSourceDetails(designer: "Maker", licence: "CC BY-ND 4.0")

    // MARK: Source details on STL copies

    func testSourceDetailsRoundTripThroughModelsJSON() throws {
        var local = LocalModel(name: "Hook", filePath: "/tmp/hook.stl")
        local.sourceDetails = ModelSourceDetails(designer: "Maker", licence: "CC BY 4.0", source: "https://example.com/m/1",
                                                 copyright: "© Maker")
        let data = try JSONEncoder().encode([local])
        let decoded = try JSONDecoder().decode([LocalModel].self, from: data)
        XCTAssertEqual(decoded.first?.sourceDetails, local.sourceDetails)
    }

    func testOlderLibraryWithoutSourceDetailsStillLoads() throws {
        let json = #"[{"id":"\#(UUID().uuidString)","name":"Old","filePath":"/tmp/old.stl","added":0}]"#
        let decoded = try JSONDecoder().decode([LocalModel].self, from: Data(json.utf8))
        XCTAssertEqual(decoded.count, 1)
        XCTAssertNil(decoded[0].sourceDetails)
    }

    func testDamagedSourceDetailsNeverStopTheLibraryLoading() throws {
        let id = UUID().uuidString
        for value in [#""a string""#, "42", "[1,2]", #"{"designer":7,"licence":["x"],"source":null}"#] {
            let json = #"[{"id":"\#(id)","name":"M","filePath":"/tmp/m.stl","added":0,"sourceDetails":\#(value)}]"#
            let decoded = try JSONDecoder().decode([LocalModel].self, from: Data(json.utf8))
            XCTAssertEqual(decoded.count, 1, value)
            XCTAssertEqual(decoded[0].sourceDetails?.isEmpty ?? true, true, value)
        }
    }

    func testDecodedSourceDetailsAreCleanedButNotUnescapedAgain() throws {
        let json = #"{"designer":"A‮b\nc","licence":"Terms &amp; conditions","copyright":"   "}"#
        let details = try JSONDecoder().decode(ModelSourceDetails.self, from: Data(json.utf8))
        XCTAssertEqual(details.designer, "A b c")
        XCTAssertEqual(details.licence, "Terms &amp; conditions", "already-cleaned text isn't unescaped a second time")
        XCTAssertNil(details.copyright)
        let long = String(repeating: "x", count: 500)
        let capped = try JSONDecoder().decode(ModelSourceDetails.self, from: Data(#"{"source":"\#(long)"}"#.utf8))
        XCTAssertEqual(capped.source?.count, modelSourceFieldLimit)
    }

    func testDetailsShownPreferTheFileThenTheCarriedOverOnes() {
        let fromFile = ModelSourceDetails(designer: "File")
        XCTAssertEqual(modelSourceDetailsToShow(stored: nonCommercial, fromFile: fromFile), fromFile)
        XCTAssertEqual(modelSourceDetailsToShow(stored: nonCommercial, fromFile: ModelSourceDetails()), nonCommercial)
        XCTAssertTrue(modelSourceDetailsToShow(stored: nil, fromFile: ModelSourceDetails()).isEmpty)
    }

    func testCopiesCarryDetailsFromTheFileOrTheModelTheyWereMadeFrom() {
        var threeMF = LocalModel(name: "Vase", filePath: "/tmp/vase.3mf")
        XCTAssertEqual(sourceDetailsForCopy(of: threeMF, fromFile: nonCommercial), nonCommercial, "Save STL Copy of a 3MF")
        XCTAssertNil(sourceDetailsForCopy(of: threeMF), "nothing to carry")
        threeMF.sourceDetails = noDerivatives
        XCTAssertEqual(sourceDetailsForCopy(of: threeMF), noDerivatives, "a copy of a copy")
        XCTAssertNil(sourceDetailsForCopy(of: LocalModel(name: "Plain", filePath: "/tmp/p.stl"), fromFile: ModelSourceDetails()))
    }

    func testNoDerivativesAdvisoryFiresOnAnEditedCopy() {
        var copy = LocalModel(name: "Vase STL copy", filePath: "/tmp/copy.stl")
        copy.sourceDetails = noDerivatives
        let shown = modelSourceDetailsToShow(stored: copy.sourceDetails, fromFile: ModelSourceDetails())
        XCTAssertNil(modelLicenceAdvisory(shown, edited: modelIsEditedCopy(copy)), "an unchanged STL copy isn't a derivative")
        var edited = copy
        edited.designImprovement = DesignImprovementRecord(sourceID: copy.id, kind: .bottomChamfer, sizeMM: 0.5, created: Date())
        XCTAssertEqual(modelLicenceAdvisory(shown, edited: modelIsEditedCopy(edited)), modelLicenceAdvisoryText)
    }

    // MARK: Listing actions

    func testListingAdvisoryUsesFileOrCarriedOverDetails() {
        var model = LocalModel(name: "Hook", filePath: "/tmp/hook.stl")
        XCTAssertNil(listingLicenceAdvisory(model: model, fileDetails: nil))
        XCTAssertEqual(listingLicenceAdvisory(model: LocalModel(name: "V", filePath: "/tmp/v.3mf"), fileDetails: nonCommercial),
                       modelLicenceAdvisoryText)
        model.sourceDetails = nonCommercial
        XCTAssertEqual(listingLicenceAdvisory(model: model, fileDetails: nil), modelLicenceAdvisoryText)
        model.sourceDetails = noDerivatives
        XCTAssertNil(listingLicenceAdvisory(model: model, fileDetails: nil))
    }

    func testCopiedMessageAddsTheAdvisoryButTheCopiedTextNeverDoes() {
        let message = listingDetailsCopiedMessage(hasSize: true, scaleSuspect: false, licenceAdvisory: modelLicenceAdvisoryText)
        XCTAssertEqual(message, "Listing details copied. " + modelLicenceAdvisoryText + " " + listingProductionPartnerNote)
        XCTAssertEqual(listingDetailsCopiedMessage(hasSize: true, scaleSuspect: false),
                       "Listing details copied. " + listingProductionPartnerNote)
        let text = listingDetailsText(ListingDetailsFacts(extentMM: SIMD3(10, 10, 10), objectCount: 1, materialName: "PLA", weight: nil))
        XCTAssertFalse(text.contains("licence"))
    }

    // MARK: Drag folders

    func testDragFoldersLastADayBetweenDrags() {
        XCTAssertEqual(ModelDragExport.staleAge, 24 * 60 * 60)
    }

    func testDragFolderNamesAreStrict() {
        XCTAssertTrue(ModelDragExport.isDragFolderName("SlantStudio-Drag-\(UUID().uuidString)"))
        XCTAssertFalse(ModelDragExport.isDragFolderName("SlantStudio-Drag-1"))
        XCTAssertFalse(ModelDragExport.isDragFolderName("SlantStudio-Drag-"))
        XCTAssertFalse(ModelDragExport.isDragFolderName("SlantStudio-OpenSCAD-\(UUID().uuidString)"))
        XCTAssertFalse(isPersonalisationTempFolderName("SlantStudio-Drag-\(UUID().uuidString)"))
    }

    func testStaleDragFolderSelection() {
        let now = Date()
        let fresh = "SlantStudio-Drag-\(UUID().uuidString)"
        let old = "SlantStudio-Drag-\(UUID().uuidString)"
        let undated = "SlantStudio-Drag-\(UUID().uuidString)"
        let entries: [(name: String, created: Date?)] = [
            (fresh, now.addingTimeInterval(-60)), (old, now.addingTimeInterval(-25 * 60 * 60)), (undated, nil),
            ("SlantStudio-Drag-x", now.addingTimeInterval(-99 * 60 * 60)), ("Other", nil)
        ]
        XCTAssertEqual(Set(ModelDragExport.staleFolderNames(entries, now: now, minimumAge: nil)), [fresh, old, undated])
        XCTAssertEqual(ModelDragExport.staleFolderNames(entries, now: now, minimumAge: ModelDragExport.staleAge), [old])
    }

    func testLaunchCleanUpRemovesOnlyDragFolders() throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("r5fix-drag-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        let library = temporary.appendingPathComponent("lib.stl")
        try Data("solid".utf8).write(to: library)
        let copy = try ModelDragExport.makeCopy(of: library, name: "Hook", in: temporary)
        let keep = temporary.appendingPathComponent("SlantStudio-Drag-keep", isDirectory: true)
        try FileManager.default.createDirectory(at: keep, withIntermediateDirectories: true)
        let stray = temporary.appendingPathComponent("SlantStudio-Drag-\(UUID().uuidString)")
        try Data("file".utf8).write(to: stray)

        ModelDragExport.removeLeftoverFolders(in: temporary, otherInstanceMayBeRunning: true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: copy.path), "another copy of Studio's recent drag stays")
        ModelDragExport.removeLeftoverFolders(in: temporary, otherInstanceMayBeRunning: false)
        XCTAssertFalse(FileManager.default.fileExists(atPath: copy.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: keep.path), "names that aren't prefix + UUID stay")
        XCTAssertTrue(FileManager.default.fileExists(atPath: stray.path), "plain files stay")
        XCTAssertTrue(FileManager.default.fileExists(atPath: library.path))
    }
}
