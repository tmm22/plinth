import XCTest
@testable import Plinth

/// Round 17: Slant keeps one file per owner and name (M-67), file IDs (M-28), Upload from URL's type (M-27), model
/// analysis units and age (M-30, M-23) and catalog dimensions (M-33). All values are invented.
final class FilesRound17Tests: XCTestCase {
    private func files(_ names: [Any]) -> [Record] {
        names.enumerated().map { Record(values: ["publicFileServiceId": "file-\($0.offset)", "name": $0.element]) }
    }

    // MARK: Same-name check (M-67)

    func testNameConflictIgnoresCaseSpacingAndAModelExtension() {
        let listed = files(["Phone Stand", "Hook  v2.stl", 42, NSNull()])
        XCTAssertEqual(slantUploadNameConflict(name: "phone stand", files: listed), "Phone Stand")
        XCTAssertEqual(slantUploadNameConflict(name: "  PHONE   STAND ", files: listed), "Phone Stand")
        XCTAssertEqual(slantUploadNameConflict(name: "Phone Stand.3MF", files: listed), "Phone Stand")
        XCTAssertEqual(slantUploadNameConflict(name: "hook v2", files: listed), "Hook  v2.stl")
        XCTAssertNil(slantUploadNameConflict(name: "Phone Stand 2", files: listed))
        XCTAssertNil(slantUploadNameConflict(name: "42", files: listed), "a name that isn't text is never matched")
        XCTAssertNil(slantUploadNameConflict(name: "   ", files: listed))
        XCTAssertNil(slantUploadNameConflict(name: "Phone Stand", files: []))
        // Only model extensions are dropped: "v1.5" is part of the name.
        XCTAssertNil(slantUploadNameConflict(name: "Bracket v1", files: files(["Bracket v1.5"])))
    }

    func testUniqueNameTakesTheNextFreeNumber() {
        XCTAssertEqual(slantUploadUniqueName(name: "Phone Stand", files: files(["Phone Stand"])), "Phone Stand 2")
        XCTAssertEqual(slantUploadUniqueName(name: "Phone Stand", files: files(["Phone Stand", "phone stand 2", "Phone Stand 3.stl"])),
                       "Phone Stand 4")
        XCTAssertEqual(slantUploadUniqueName(name: "Bracket 50", files: files(["Bracket 50"])), "Bracket 50 2",
                       "a trailing number is part of the name, never a counter")
        XCTAssertEqual(slantUploadUniqueName(name: "  Hook   v2 ", files: files(["Hook v2"])), "Hook v2 2")
        let suggested = slantUploadUniqueName(name: "Phone Stand", files: files(["Phone Stand", "Phone Stand 2"]))
        XCTAssertNil(slantUploadNameConflict(name: suggested, files: files(["Phone Stand", "Phone Stand 2"])))
    }

    func testNameCheckAndItsCopy() {
        XCTAssertEqual(slantUploadNameCheck(name: "Hook", files: files(["Phone Stand"])), .clear)
        XCTAssertEqual(slantUploadNameCheck(name: "hook", files: files(["Hook"])), .conflict(existing: "Hook", suggested: "hook 2"))
        XCTAssertEqual(slantUploadNameConflictMessage(existing: "Hook"),
                       "A file named “Hook” is already in your Slant files. Uploading with this name replaces that file for every draft that uses it, and possibly for orders not yet printed.")
        let failed = slantUploadNameCheckFailedMessage(name: "Hook", reason: "Slant didn’t reply in time.")
        XCTAssertTrue(failed.contains("nothing was uploaded"))
        XCTAssertTrue(failed.contains("Slant didn’t reply in time."))
        XCTAssertTrue(failed.hasSuffix(slantUploadNameCheckRetryInModels))
        XCTAssertFalse(failed.contains("Refresh"), "the next step is the upload button, not Refresh")
        XCTAssertFalse(slantUploadNameCheckFailedMessage(name: "Hook", reason: " ").contains("  "))
    }

    func testFileNamePageMustBeAList() {
        XCTAssertTrue(slantFileNamePageIsReadable(["data": [] as [Any]]))
        XCTAssertTrue(slantFileNamePageIsReadable(["data": [["name": "Hook", "publicFileServiceId": "f-1"]]]))
        XCTAssertTrue(slantFileNamePageIsReadable(["data": ["files": [["name": "Hook"]]]]))
        XCTAssertFalse(slantFileNamePageIsReadable(nil))
        XCTAssertFalse(slantFileNamePageIsReadable(["success": true]))
        XCTAssertFalse(slantFileNamePageIsReadable(["data": ["name": "Hook"]]))
        XCTAssertFalse(slantFileNamePageIsReadable(["data": [["fileName": "Hook"]]]), "rows that name no file can't be checked")
        XCTAssertFalse(slantFileNamePageIsReadable(["data": ["Hook"]]))
    }

    // MARK: Links after an upload Slant stored in an existing file (M-67)

    func testOnlyTheUploadedModelKeepsTheLink() {
        let uploaded = LocalModel(name: "Hook", filePath: "/tmp/hook.stl", remoteID: "file-1")
        let earlier = LocalModel(name: "Hook (old)", filePath: "/tmp/hook-old.stl", remoteID: " file-1 ")
        let other = LocalModel(name: "Stand", filePath: "/tmp/stand.stl", remoteID: "file-2")
        let unlinked = LocalModel(name: "Clip", filePath: "/tmp/clip.stl")
        let models = [uploaded, earlier, other, unlinked]
        XCTAssertEqual(modelsLosingLinkAfterUpload(fileID: "file-1", uploadedModelID: uploaded.id, in: models), [earlier.id])
        XCTAssertEqual(modelsLosingLinkAfterUpload(fileID: "file-1", uploadedModelID: nil, in: models), [uploaded.id, earlier.id],
                       "Upload from URL adds no library model, so every linked model loses the link")
        XCTAssertEqual(modelsLosingLinkAfterUpload(fileID: "file-3", uploadedModelID: uploaded.id, in: models), [])
        XCTAssertEqual(modelsLosingLinkAfterUpload(fileID: " ", uploadedModelID: nil, in: models), [])
    }

    func testLinkMovedNotice() {
        XCTAssertNil(uploadLinkMovedNotice(uploadedName: "Hook", otherNames: []))
        let one = uploadLinkMovedNotice(uploadedName: "Hook", otherNames: ["Hook (old)"]) ?? ""
        XCTAssertTrue(one.contains("“Hook (old)” is no longer linked"))
        XCTAssertTrue(one.contains("now holds “Hook”"))
        let two = uploadLinkMovedNotice(uploadedName: "Hook", otherNames: ["A", "B"]) ?? ""
        XCTAssertTrue(two.contains("2 other models"))
    }

    // MARK: Personalised upload names (M-67)

    func testPersonalisedUploadsNeverShareAName() {
        let base = batchPersonaliseUploadName(source: .template, sourceOrderID: "A-1", index: 0, count: 1)
        XCTAssertEqual(base, "Personalised model")
        let first = batchPersonaliseUniqueUploadName(base)
        let second = batchPersonaliseUniqueUploadName(base)
        XCTAssertNotEqual(first, second, "two orders with the same base never get the same name")
        var seen = Set<String>()
        for _ in 0..<2000 { XCTAssertTrue(seen.insert(batchPersonaliseUniqueUploadName(base)).inserted) }
        XCTAssertFalse(seen.contains(first) || seen.contains(second))
        // The format: Studio's neutral name, then eight lower-case hex characters.
        let pattern = #"^Personalised model · [0-9a-f]{8}$"#
        XCTAssertNotNil(first.range(of: pattern, options: .regularExpression), first)
        XCTAssertEqual(batchPersonaliseUniqueUploadName("Etsy order 123 personalised 1 of 2", token: "7f3a9c21"),
                       "Etsy order 123 personalised 1 of 2 · 7f3a9c21")
        XCTAssertEqual(batchPersonaliseUniqueUploadName("  ", token: "abc123"), "Personalised model · abc123")
    }

    // MARK: File IDs (M-28)

    func testFileIDsAreNonEmptyStringsOnly() {
        XCTAssertNil(uploadedFileID(["id": 9999]))
        XCTAssertNil(uploadedFileID(["publicFileServiceId": 12, "id": 9999]))
        XCTAssertEqual(uploadedFileID(["publicFileServiceId": 12, "publicId": " f-9 "]), "f-9")
        XCTAssertEqual(uploadedFileID(["publicFileServiceId": "", "id": "f-8"]), "f-8")
        guard case .unknown = batchPersonaliseUploadOutcome(response: ["id": 9999, "name": "Personalised model"]) else {
            return XCTFail("the upload placeholder's internal number isn't a file ID")
        }
        XCTAssertEqual(batchPersonaliseUploadOutcome(response: ["publicFileServiceId": " f-1 "]), .uploaded(fileID: "f-1"))
    }

    // MARK: Upload from URL's type (M-27)

    func testURLTypeTakesARecognisedLinkExtensionThenTheName() {
        XCTAssertEqual(importModelType(url: "https://cdn.example/download.php", name: "part.3mf"), "3mf")
        XCTAssertEqual(importModelType(url: "https://cdn.example/download.php?id=1", name: "part.obj"), "obj")
        XCTAssertEqual(importModelType(url: "https://cdn.example/a.stl", name: "part.3mf"), "stl", "a link's .stl wins over the name")
        XCTAssertEqual(importModelType(url: "https://cdn.example/A.OBJ", name: "part.3mf"), "obj")
        XCTAssertEqual(importModelType(url: "https://cdn.example/download.php", name: "part"), "stl")
        XCTAssertEqual(importModelType(url: "https://cdn.example/a.3mf", name: "part"), "3mf")
    }

    // MARK: Model analysis (M-30, M-23)

    func testDimensionUnitsComeFromSlantsDimensionsUnit() {
        let metrics: [String: Any] = ["x": 10, "units": ["dimensions": "cm", "weight": "g", "volume": NSNull()]]
        XCTAssertEqual(metricUnit("x", metrics), "cm")
        XCTAssertEqual(metricUnit("z", metrics), "cm")
        XCTAssertEqual(metricUnit("weight", metrics), "g", "a null unit elsewhere doesn't hide the others")
        XCTAssertEqual(metricUnit("volume", metrics), "cm³")
        XCTAssertEqual(metricUnit("x", ["x": 10]), "mm")
        XCTAssertEqual(metricUnit("x", ["units": ["x": "in", "dimensions": "cm"]]), "in")
    }

    func testPendingCaptionIsWordedByAge() {
        let uploaded = Date(timeIntervalSince1970: 1_900_000_000)
        let fresh = metricsPendingCaption(createdAt: uploaded, now: uploaded.addingTimeInterval(600), formatter: { _ in "1 Mar" })
        XCTAssertTrue(fresh.hasPrefix("Analysing…"))
        XCTAssertTrue(metricsPendingCaption(createdAt: nil, now: uploaded).hasPrefix("Analysing…"))
        XCTAssertTrue(metricsPendingCaption(createdAt: uploaded.addingTimeInterval(60), now: uploaded).hasPrefix("Analysing…"))
        let old = metricsPendingCaption(createdAt: uploaded, now: uploaded.addingTimeInterval(6 * 86_400), formatter: { _ in "1 Mar" })
        XCTAssertTrue(old.contains("hasn’t measured this model since it was uploaded on 1 Mar"))
        XCTAssertTrue(old.contains("Check Again"))
        XCTAssertFalse(old.lowercased().contains("estimate"), "nothing is claimed about estimates")
        XCTAssertFalse(old.contains("3MF"), "nothing is claimed about why")
        let record = Record(values: ["createdAt": "2030-03-01T10:00:00.123Z"])
        XCTAssertNotNil(cloudFileDate(record, "createdAt"))
        XCTAssertNil(cloudFileDate(Record(values: ["createdAt": 5]), "createdAt"))
    }

    // MARK: Catalog dimensions (M-33)

    func testDimensionsAreShownAsSlantWritesThem() {
        XCTAssertEqual(catalogDimensionsText("Ø6 x 2 mm"), "Ø6 x 2 mm")
        XCTAssertEqual(catalogDimensionsText("1 in x 2 in"), "1 in x 2 in")
        XCTAssertEqual(catalogDimensionsText("12ft x 1.46in x 2.27 in"), "12ft x 1.46in x 2.27 in")
        XCTAssertEqual(catalogDimensionsText("\u{200E}6.26 x 5.28 x 2.91"), "6.26 x 5.28 x 2.91")
        XCTAssertEqual(catalogDimensionsText(".6 x 1.2 x 2.4 "), ".6 x 1.2 x 2.4")
        XCTAssertEqual(catalogDimensionsText("\u{200F} 31 x 34 x 50 mm\u{200E}"), "31 x 34 x 50 mm")
        XCTAssertEqual(catalogDimensionsText("Ø0.5 x 3"), "Ø0.5 x 3")
        XCTAssertNil(catalogDimensionsText("0 x 0 x 0"))
        XCTAssertNil(catalogDimensionsText("0.0 x 0 x 0 mm"))
        XCTAssertNil(catalogDimensionsText(""))
        XCTAssertNil(catalogDimensionsText(" \u{200E} "))
        XCTAssertEqual(catalogDimensionsText("Varies"), "Varies")
    }

    func testCatalogRowsNeverAddAUnitToDimensions() {
        let component = Record(values: ["dimensions": "Ø6 x 2 mm", "dimensionUnit": "mm"])
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: componentFactRows(component))["Dimensions"], "Ø6 x 2 mm")
        let inches = Record(values: ["dimensions": "1 in x 2 in", "dimensionUnit": "mm"])
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: componentFactRows(inches))["Dimensions"], "1 in x 2 in")
        XCTAssertNil(Dictionary(uniqueKeysWithValues: componentFactRows(Record(values: ["dimensions": "0 x 0 x 0", "dimensionUnit": "mm"])))["Dimensions"])
        let stationery = Record(values: ["dimensions": "\u{200E}6.26 x 5.28 x 2.91", "dimensionUnit": "mm"])
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: stationeryFactRows(stationery))["Dimensions"], "6.26 x 5.28 x 2.91")
        XCTAssertEqual(stationeryCardSubtitle(Record(values: ["dimensions": "0 x 0 x 0"])), "Stationery")
    }
}
