import XCTest
@testable import Plinth

final class ModelsRound5Tests: XCTestCase {
    private func model(metadata: String, objects: String? = nil) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <model unit="millimeter" xml:lang="en-US" xmlns="http://schemas.microsoft.com/3dmanufacturing/core/2015/02" xmlns:BambuStudio="http://schemas.bambulab.com/package/2021">
        \(metadata)
         <resources>\(objects ?? "<object id=\"1\" type=\"model\">\(cubeMeshXML(size: 10))</object>")</resources>
         <build><item objectid="1"/></build>
        </model>
        """
    }

    // MARK: Metadata reading

    func testCoreSpecMetadataIsRead() throws {
        let xml = model(metadata: """
         <metadata name="Title">Bracket</metadata>
         <metadata name="Designer">Jane Maker</metadata>
         <metadata name="Copyright">© 2026 Jane Maker</metadata>
         <metadata name="LicenseTerms">CC BY-NC-SA 4.0</metadata>
         <metadata name="Application">PrusaSlicer-2.8.0</metadata>
        """)
        let parsed = try ThreeMFReader.read(package(model: xml))
        XCTAssertEqual(parsed.sourceDetails.designer, "Jane Maker")
        XCTAssertEqual(parsed.sourceDetails.licence, "CC BY-NC-SA 4.0")
        XCTAssertEqual(parsed.sourceDetails.copyright, "© 2026 Jane Maker")
        XCTAssertNil(parsed.sourceDetails.source)
        XCTAssertEqual(parsed.sourceDetails.rows.map(\.label), ["Designer", "Licence", "Copyright"])
        XCTAssertEqual(parsed.mesh.triangleCount, 12, "geometry is unchanged by the metadata pass")
    }

    func testBambuMetadataAndDoubleEscaping() throws {
        // Bambu Studio escapes values before writing them, so "&" arrives as "&amp;amp;" in the XML.
        let xml = model(metadata: """
         <metadata name="Application">BambuStudio-02.01.00.59</metadata>
         <metadata name="BambuStudio:3mfVersion">1</metadata>
         <metadata name="CopyRight">Smith &amp;amp; Co</metadata>
         <metadata name="Designer">maker_42</metadata>
         <metadata name="DesignerUserId">123456</metadata>
         <metadata name="License">BY-NC-ND</metadata>
         <metadata name="Origin">https://makerworld.com/en/models/1</metadata>
        """)
        let details = try ThreeMFReader.read(package(model: xml)).sourceDetails
        XCTAssertEqual(details.designer, "maker_42")
        XCTAssertEqual(details.licence, "BY-NC-ND")
        XCTAssertEqual(details.source, "https://makerworld.com/en/models/1")
        XCTAssertEqual(details.copyright, "Smith & Co")
    }

    func testLicenseTermsPreferredOverBambuLicenseAndFirstValueWins() {
        let details = modelSourceDetails(fromMetadata: [
            ("License", "BY"), ("Designer", "  "), ("Designer", "Second"), ("LicenseTerms", "CC0"), ("designer", "Third")
        ])
        XCTAssertEqual(details.licence, "CC0")
        XCTAssertEqual(details.designer, "Second", "an empty value doesn't count")
        XCTAssertEqual(modelSourceDetails(fromMetadata: [("License", "BY")]).licence, "BY")
        XCTAssertTrue(modelSourceDetails(fromMetadata: [("Title", "x"), ("Vendor:Designer", "y")]).isEmpty,
                      "only the unprefixed names are read")
    }

    func testObjectLevelAndLateMetadataIgnored() throws {
        let objects = """
        <object id="1" type="model"><metadatagroup><metadata name="Designer">Object level</metadata></metadatagroup>\(cubeMeshXML(size: 10))</object>
        """
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <model unit="millimeter" xmlns="http://schemas.microsoft.com/3dmanufacturing/core/2015/02">
         <resources>\(objects)</resources>
         <build><item objectid="1"/></build>
         <metadata name="Designer">After resources</metadata>
        </model>
        """
        let parsed = try ThreeMFReader.read(package(model: xml))
        XCTAssertTrue(parsed.sourceDetails.isEmpty)
        XCTAssertEqual(parsed.mesh.triangleCount, 12)
    }

    func testFileWithoutMetadataHasNoDetails() throws {
        let parsed = try ThreeMFReader.read(package(model: modelXML(resources: "<object id=\"1\">\(cubeMeshXML())</object>",
                                                                   build: "<item objectid=\"1\"/>")))
        XCTAssertTrue(parsed.sourceDetails.isEmpty)
        XCTAssertTrue(ModelSourceDetails().rows.isEmpty)
    }

    func testMetadataReaderBounds() {
        let long = String(repeating: "a", count: 10_000)
        var entries = ""
        for index in 0..<100 { entries += "<metadata name=\"K\(index)\">v</metadata>" }
        let xml = "<model><metadata name=\"Designer\">\(long)</metadata>\(entries)<resources/></model>"
        let read = ThreeMFMetadataReader.entries(in: Data(xml.utf8))
        XCTAssertEqual(read.count, ThreeMFMetadataReader.maximumEntries)
        XCTAssertLessThanOrEqual(read[0].value.utf16.count, 2 * ThreeMFMetadataReader.maximumValueLength)
        let designer = modelSourceDetails(fromMetadata: read).designer
        XCTAssertEqual(designer?.count, modelSourceFieldLimit)
        XCTAssertEqual(designer?.hasSuffix("…"), true)
    }

    func testMetadataReaderRefusesDocumentTypesAndToleratesJunk() {
        let dtd = "<?xml version=\"1.0\"?><!DOCTYPE model [<!ENTITY x \"boom\">]><model><metadata name=\"Designer\">&x;</metadata></model>"
        XCTAssertTrue(ThreeMFMetadataReader.entries(in: Data(dtd.utf8)).isEmpty)
        XCTAssertTrue(ThreeMFMetadataReader.entries(in: Data("not xml".utf8)).isEmpty)
        XCTAssertTrue(ThreeMFMetadataReader.entries(in: Data()).isEmpty)
        // A truncated part keeps what was read before the error.
        let truncated = "<model><metadata name=\"Designer\">Ann</metadata><metadata name=\"License\">BY"
        XCTAssertEqual(ThreeMFMetadataReader.entries(in: Data(truncated.utf8)).first?.value, "Ann")
        let cdata = "<model><metadata name=\"Designer\"><![CDATA[Bob <b>]]></metadata><resources/></model>"
        XCTAssertEqual(ThreeMFMetadataReader.entries(in: Data(cdata.utf8)).first?.value, "Bob <b>")
    }

    func testSanitisedMetadataValue() {
        XCTAssertEqual(sanitisedMetadataValue("  Jane\n\tMaker\r\n "), "Jane Maker")
        XCTAssertEqual(sanitisedMetadataValue("a\u{202E}b\u{0007}c"), "a b c")
        XCTAssertEqual(sanitisedMetadataValue("&amp;lt;b&amp;gt;"), "&lt;b&gt;", "only one extra level is undone")
        XCTAssertEqual(sanitisedMetadataValue("Tom &amp; Jerry"), "Tom & Jerry")
        XCTAssertNil(sanitisedMetadataValue(" \n "))
        XCTAssertNil(sanitisedMetadataValue(""))
        XCTAssertEqual(sanitisedMetadataValue("abcdef", limit: 4), "abc…")
        XCTAssertEqual(sanitisedMetadataValue("[link](https://example.com)"), "[link](https://example.com)")
    }

    // MARK: Licence classification

    func testNonCommercialLicences() {
        for text in ["CC BY-NC-SA 4.0", "BY-NC", "BY-NC-ND", "cc-by-nc", "Creative Commons - Attribution - Non-Commercial",
                     "Attribution-NonCommercial-ShareAlike 4.0 International", "Personal use only", "For personal use only.",
                     "Not for commercial use", "Commercial use is prohibited", "Standard Digital File License",
                     "NON COMMERCIAL", "Créative Commons BY-NC"] {
            XCTAssertTrue(modelLicenceConcerns(text).contains(.nonCommercial), text)
        }
    }

    func testLicencesWithoutNonCommercialTerms() {
        for text in ["CC BY 4.0", "BY-SA", "CC0", "GNU GPL v3", "MIT", "Commercial use allowed", "Free for commercial use",
                     "© 2026 Acme, Raleigh NC", "All rights reserved", "Incorporated", "", "   ", "BY-ND"] {
            XCTAssertFalse(modelLicenceConcerns(text).contains(.nonCommercial), text)
        }
    }

    func testNoDerivatives() {
        for text in ["BY-ND", "CC BY-NC-ND 4.0", "Attribution-NoDerivatives 4.0", "No derivatives", "CC BY-ND"] {
            XCTAssertTrue(modelLicenceConcerns(text).contains(.noDerivatives), text)
        }
        for text in ["CC BY-SA", "Charlotte ND", "BY-NC"] {
            XCTAssertFalse(modelLicenceConcerns(text).contains(.noDerivatives), text)
        }
    }

    func testAdvisory() {
        let nc = ModelSourceDetails(licence: "BY-NC")
        XCTAssertEqual(modelLicenceAdvisory(nc, edited: false), "This licence may not allow selling prints. Check before listing.")
        let nd = ModelSourceDetails(licence: "CC BY-ND 4.0")
        XCTAssertNil(modelLicenceAdvisory(nd, edited: false), "prints of the unchanged model aren't a derivative")
        XCTAssertNotNil(modelLicenceAdvisory(nd, edited: true))
        XCTAssertNil(modelLicenceAdvisory(ModelSourceDetails(designer: "Jane"), edited: true))
        XCTAssertNil(modelLicenceAdvisory(ModelSourceDetails(licence: "CC BY 4.0"), edited: true))
        XCTAssertNotNil(modelLicenceAdvisory(ModelSourceDetails(copyright: "Jane, personal use only"), edited: false),
                        "a licence written in the copyright line counts")
    }

    func testEditedCopy() {
        var local = LocalModel(name: "Part", filePath: "/tmp/part.stl")
        XCTAssertFalse(modelIsEditedCopy(local))
        local.designImprovement = DesignImprovementRecord(sourceID: UUID(), kind: .bottomChamfer, sizeMM: 0.5, created: Date())
        XCTAssertTrue(modelIsEditedCopy(local))
    }

    // MARK: Drag out of the library

    func testDragCopyIsNamedAndLeavesTheLibraryFile() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("r5-drag-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = root.appendingPathComponent("Library", isDirectory: true)
        let temporary = root.appendingPathComponent("T", isDirectory: true)
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        let source = library.appendingPathComponent("\(UUID().uuidString).3mf")
        try Data("model".utf8).write(to: source)

        let copy = try ModelDragExport.makeCopy(of: source, name: "Wall: Hook/Large", in: temporary)
        XCTAssertEqual(copy.lastPathComponent, "Wall- Hook-Large.3mf")
        XCTAssertEqual(try Data(contentsOf: copy), Data("model".utf8))
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        XCTAssertTrue(ModelDragExport.isDragCopy(copy, temporaryDirectory: temporary))
        XCTAssertFalse(ModelDragExport.isDragCopy(source, temporaryDirectory: temporary))
        XCTAssertTrue(copy.deletingLastPathComponent().lastPathComponent.hasPrefix("Plinth-Drag-"))
        XCTAssertFalse(ModelDragExport.isDragCopy(temporary.appendingPathComponent("Plinth-Drag-x"), temporaryDirectory: temporary),
                       "the folder itself isn't a dropped model")
        XCTAssertFalse(ModelDragExport.isDragCopy(temporary.appendingPathComponent("Other/Plinth-Drag-x/a.stl"),
                                                  temporaryDirectory: temporary))
        // A file in Slant Studio's drag folder is a drag copy too, so it is never imported.
        XCTAssertTrue(ModelDragExport.isDragCopy(temporary.appendingPathComponent("SlantStudio-Drag-\(UUID().uuidString)/Hook.stl"),
                                                 temporaryDirectory: temporary))
        XCTAssertFalse(ModelDragExport.isDragCopy(temporary.appendingPathComponent("SlantStudio-Drag-x"), temporaryDirectory: temporary),
                       "the folder itself isn't a dropped model")
        XCTAssertFalse(ModelDragExport.isDragCopy(temporary.appendingPathComponent("Other/SlantStudio-Drag-x/a.stl"),
                                                  temporaryDirectory: temporary))
        XCTAssertFalse(ModelDragExport.isDragCopy(temporary.appendingPathComponent("PlinthListing-x/a.stl"), temporaryDirectory: temporary))

        // A missing library file gives no copy and leaves no folder behind.
        XCTAssertThrowsError(try ModelDragExport.makeCopy(of: library.appendingPathComponent("gone.stl"), name: "Gone", in: temporary))
        let folders = try FileManager.default.contentsOfDirectory(atPath: temporary.path)
        XCTAssertEqual(folders.count, 1)

        // Fresh folders stay; old ones go; other folders are never touched.
        let other = temporary.appendingPathComponent("Keep", isDirectory: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        ModelDragExport.removeStaleFolders(in: temporary)
        XCTAssertTrue(FileManager.default.fileExists(atPath: copy.path))
        ModelDragExport.removeStaleFolders(in: temporary, now: Date().addingTimeInterval(ModelDragExport.staleAge + 60))
        XCTAssertFalse(FileManager.default.fileExists(atPath: copy.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: other.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
    }

    func testDropFilterSkipsLibraryFilesAndDragCopies() {
        let support = URL(fileURLWithPath: "/tmp/r5-support", isDirectory: true)
        let temporary = URL(fileURLWithPath: "/tmp/r5-temp", isDirectory: true)
        let outside = URL(fileURLWithPath: "/Users/someone/Downloads/hook.stl")
        let managed = support.appendingPathComponent("Models/ABC.stl")
        let dragged = temporary.appendingPathComponent("Plinth-Drag-1/Hook.stl")
        let legacyDragged = temporary.appendingPathComponent("SlantStudio-Drag-1/Hook.stl")
        XCTAssertEqual(modelDropURLsToImport([outside, managed, dragged], supportDirectory: support, temporaryDirectory: temporary),
                       [outside])
        XCTAssertEqual(modelDropURLsToImport([legacyDragged, outside], supportDirectory: support, temporaryDirectory: temporary),
                       [outside], "Slant Studio's drag copies aren't imported either")
        XCTAssertEqual(modelDropURLsToImport([], supportDirectory: support, temporaryDirectory: temporary), [])
        // Dropped on the Dock icon: the drag copy is skipped too.
        XCTAssertEqual(queuedModelOpens([], adding: [dragged, outside], temporaryDirectory: temporary), [outside])
    }
}
