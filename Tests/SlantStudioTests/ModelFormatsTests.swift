import XCTest
import Compression
import simd
@testable import SlantStudio

// MARK: - Test ZIP writer

/// Builds ZIP packages in memory, independent of the reader under test except for the CRC (checked against a known value).
struct TestZip {
    struct Item {
        var name: String
        var data: Data
        var deflate = false
        /// Overrides written into the central directory, to build damaged or hostile archives.
        var declaredUncompressed: UInt32?
        var declaredCompressed: UInt32?
        var flags: UInt16 = 0
        var crcOverride: UInt32?
    }

    var items: [Item] = []
    var zip64 = false
    var declaredEntryCount: UInt16?

    mutating func add(_ name: String, _ text: String, deflate: Bool = false) {
        items.append(Item(name: name, data: Data(text.utf8), deflate: deflate))
    }

    static func rawDeflate(_ data: Data) -> Data {
        guard !data.isEmpty else { return Data() }
        let capacity = data.count + 1024
        var output = Data(count: capacity)
        let written = output.withUnsafeMutableBytes { out in
            data.withUnsafeBytes { input in
                compression_encode_buffer(out.bindMemory(to: UInt8.self).baseAddress!, capacity,
                                          input.bindMemory(to: UInt8.self).baseAddress!, data.count, nil, COMPRESSION_ZLIB)
            }
        }
        precondition(written > 0)
        return output.prefix(written)
    }

    func build() -> Data {
        var out = Data()
        var directory = Data()
        func u16(_ v: UInt16, _ d: inout Data) { d.append(contentsOf: [UInt8(v & 0xFF), UInt8(v >> 8)]) }
        func u32(_ v: UInt32, _ d: inout Data) { for i in 0..<4 { d.append(UInt8((v >> (8 * UInt32(i))) & 0xFF)) } }
        func u64(_ v: UInt64, _ d: inout Data) { for i in 0..<8 { d.append(UInt8((v >> (8 * UInt64(i))) & 0xFF)) } }
        for item in items {
            let payload = item.deflate ? Self.rawDeflate(item.data) : item.data
            let crc = item.crcOverride ?? zipCRC32(item.data)
            let offset = UInt32(out.count)
            let name = Data(item.name.utf8)
            let method: UInt16 = item.deflate ? 8 : 0
            // Local header; sizes here are informational (the reader trusts the central directory).
            u32(0x04034b50, &out); u16(20, &out); u16(item.flags, &out); u16(method, &out); u16(0, &out); u16(0, &out)
            u32(crc, &out); u32(UInt32(payload.count), &out); u32(UInt32(item.data.count), &out)
            u16(UInt16(name.count), &out); u16(0, &out); out.append(name); out.append(payload)

            var extra = Data()
            let compressed = item.declaredCompressed ?? UInt32(payload.count)
            let uncompressed = item.declaredUncompressed ?? UInt32(item.data.count)
            if zip64 {
                u16(0x0001, &extra); u16(24, &extra)
                u64(UInt64(uncompressed), &extra); u64(UInt64(compressed), &extra); u64(UInt64(offset), &extra)
            }
            u32(0x02014b50, &directory); u16(45, &directory); u16(45, &directory); u16(item.flags, &directory)
            u16(method, &directory); u16(0, &directory); u16(0, &directory); u32(crc, &directory)
            u32(zip64 ? 0xFFFF_FFFF : compressed, &directory); u32(zip64 ? 0xFFFF_FFFF : uncompressed, &directory)
            u16(UInt16(name.count), &directory); u16(UInt16(extra.count), &directory); u16(0, &directory)
            u16(0, &directory); u16(0, &directory); u32(0, &directory); u32(zip64 ? 0xFFFF_FFFF : offset, &directory)
            directory.append(name); directory.append(extra)
        }
        let directoryOffset = out.count
        out.append(directory)
        let count = declaredEntryCount ?? UInt16(items.count)
        if zip64 {
            let record = out.count
            u32(0x06064b50, &out); u64(44, &out); u16(45, &out); u16(45, &out); u32(0, &out); u32(0, &out)
            u64(UInt64(count), &out); u64(UInt64(count), &out); u64(UInt64(directory.count), &out); u64(UInt64(directoryOffset), &out)
            u32(0x07064b50, &out); u32(0, &out); u64(UInt64(record), &out); u32(1, &out)
            u32(0x06054b50, &out); u16(0, &out); u16(0, &out); u16(0xFFFF, &out); u16(0xFFFF, &out)
            u32(0xFFFF_FFFF, &out); u32(0xFFFF_FFFF, &out); u16(0, &out)
        } else {
            u32(0x06054b50, &out); u16(0, &out); u16(0, &out); u16(count, &out); u16(count, &out)
            u32(UInt32(directory.count), &out); u32(UInt32(directoryOffset), &out); u16(0, &out)
        }
        return out
    }
}

// MARK: - 3MF fixtures

let threeMFRels = """
<?xml version="1.0" encoding="UTF-8"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
 <Relationship Target="/3D/3dmodel.model" Id="rel0" Type="http://schemas.microsoft.com/3dmanufacturing/2013/01/3dmodel"/>
</Relationships>
"""

/// A unit cube's 8 vertices and 12 outward-facing triangles, offset by `origin` and scaled by `size`.
func cubeMeshXML(size: Double = 1, origin: SIMD3<Double> = .zero) -> String {
    var vertices = ""
    for i in 0..<8 {
        let p = origin + SIMD3(Double(i & 1), Double((i >> 1) & 1), Double((i >> 2) & 1)) * size
        vertices += "<vertex x=\"\(p.x)\" y=\"\(p.y)\" z=\"\(p.z)\"/>"
    }
    let faces = [(0, 2, 1), (1, 2, 3), (4, 5, 6), (5, 7, 6), (0, 1, 4), (1, 5, 4),
                 (2, 6, 3), (3, 6, 7), (0, 4, 2), (2, 4, 6), (1, 3, 5), (3, 7, 5)]
    let triangles = faces.map { "<triangle v1=\"\($0.0)\" v2=\"\($0.1)\" v3=\"\($0.2)\"/>" }.joined()
    return "<mesh><vertices>\(vertices)</vertices><triangles>\(triangles)</triangles></mesh>"
}

func modelXML(unit: String? = "millimeter", resources: String, build: String, extraNamespaces: String = "") -> String {
    let unitAttribute = unit.map { " unit=\"\($0)\"" } ?? ""
    return """
    <?xml version="1.0" encoding="UTF-8"?>
    <model\(unitAttribute) xml:lang="en-US" xmlns="http://schemas.microsoft.com/3dmanufacturing/core/2015/02"\(extraNamespaces)>
     <metadata name="Application">Test</metadata>
     <resources>\(resources)</resources>
     <build>\(build)</build>
    </model>
    """
}

func package(model: String, deflate: Bool = false, extra: [(String, String)] = []) -> Data {
    var zip = TestZip()
    zip.add("[Content_Types].xml", "<Types/>", deflate: deflate)
    zip.add("_rels/.rels", threeMFRels, deflate: deflate)
    zip.add("3D/3dmodel.model", model, deflate: deflate)
    for (name, text) in extra { zip.add(name, text, deflate: deflate) }
    return zip.build()
}

final class ModelFormatsTests: XCTestCase {
    private func assertClose(_ a: SIMD3<Float>, _ b: SIMD3<Float>, accuracy: Float = 1e-4, file: StaticString = #filePath, line: UInt = #line) {
        for axis in 0..<3 { XCTAssertEqual(a[axis], b[axis], accuracy: accuracy, "axis \(axis)", file: file, line: line) }
    }

    // MARK: ZIP

    func testCRC32KnownValue() {
        XCTAssertEqual(zipCRC32(Data("123456789".utf8)), 0xCBF4_3926)
        XCTAssertEqual(zipCRC32(Data()), 0)
    }

    func testZipStoredAndDeflateEntries() throws {
        var zip = TestZip()
        let text = String(repeating: "<vertex x=\"1.5\" y=\"2\" z=\"3\"/>\n", count: 200)
        zip.add("stored.txt", text)
        zip.add("deflated.txt", text, deflate: true)
        zip.add("dir/", "")
        let archive = try ZipArchive(zip.build())
        XCTAssertEqual(archive.entries.map(\.name), ["stored.txt", "deflated.txt", "dir/"])
        XCTAssertEqual(archive.entries[1].method, 8)
        XCTAssertLessThan(archive.entries[1].compressedSize, archive.entries[1].uncompressedSize)
        for entry in archive.entries.prefix(2) {
            XCTAssertEqual(String(decoding: try archive.extract(entry, limit: 1_000_000), as: UTF8.self), text)
        }
        XCTAssertEqual(try archive.extract(archive.entries[2], limit: 10), Data())
        XCTAssertEqual(archive.entry(named: "/STORED.TXT")?.name, "stored.txt")
    }

    func testZip64Directory() throws {
        var zip = TestZip()
        zip.zip64 = true
        zip.add("a.txt", "hello", deflate: true)
        zip.add("b.txt", "world")
        let archive = try ZipArchive(zip.build())
        XCTAssertEqual(archive.entries.count, 2)
        XCTAssertEqual(try archive.extract(archive.entry(named: "a.txt")!, limit: 100), Data("hello".utf8))
        XCTAssertEqual(try archive.extract(archive.entry(named: "b.txt")!, limit: 100), Data("world".utf8))
    }

    func testZipFromSystemZipTool() throws {
        let tool = URL(fileURLWithPath: "/usr/bin/zip")
        guard FileManager.default.isExecutableFile(atPath: tool.path) else { throw XCTSkip("zip is not installed") }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("_rels"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("3D"), withIntermediateDirectories: true)
        try Data(threeMFRels.utf8).write(to: folder.appendingPathComponent("_rels/.rels"))
        let model = modelXML(resources: "<object id=\"1\" type=\"model\">\(cubeMeshXML(size: 20))</object>", build: "<item objectid=\"1\"/>")
        try Data(model.utf8).write(to: folder.appendingPathComponent("3D/3dmodel.model"))
        let process = Process()
        process.executableURL = tool
        process.currentDirectoryURL = folder
        process.arguments = ["-q", "-r", "-9", "out.3mf", "_rels", "3D"]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        let parsed = try ThreeMFReader.read(Data(contentsOf: folder.appendingPathComponent("out.3mf")))
        XCTAssertEqual(parsed.mesh.triangleCount, 12)
        assertClose(parsed.mesh.maximum - parsed.mesh.minimum, SIMD3(20, 20, 20))
    }

    func testZipBombRatioRejected() throws {
        var zip = TestZip()
        zip.items.append(.init(name: "3D/3dmodel.model", data: Data(repeating: 0x20, count: 4_000_000), deflate: true))
        let archive = try ZipArchive(zip.build())
        let entry = archive.entries[0]
        XCTAssertGreaterThan(entry.uncompressedSize / entry.compressedSize, ZipArchive.maximumRatio)
        XCTAssertThrowsError(try archive.extract(entry, limit: STLMesh.maximumBytes)) {
            XCTAssertEqual($0 as? ZipArchive.ZipError, .suspiciousRatio)
        }
    }

    func testDeclaredSizeBeyondLimitRejectedBeforeInflating() throws {
        var zip = TestZip()
        zip.items.append(.init(name: "big", data: Data("tiny".utf8), declaredUncompressed: 200_000_000))
        let archive = try ZipArchive(zip.build())
        XCTAssertThrowsError(try archive.extract(archive.entries[0], limit: STLMesh.maximumBytes)) {
            XCTAssertEqual($0 as? ZipArchive.ZipError, .oversized)
        }
    }

    func testUnderstatedUncompressedSizeRejected() throws {
        var zip = TestZip()
        zip.items.append(.init(name: "a", data: Data(String(repeating: "abc", count: 100).utf8), deflate: true, declaredUncompressed: 10))
        let archive = try ZipArchive(zip.build())
        XCTAssertThrowsError(try archive.extract(archive.entries[0], limit: 1_000))
    }

    func testTruncatedAndDamagedZipsRejected() throws {
        let good = package(model: modelXML(resources: "<object id=\"1\">\(cubeMeshXML())</object>", build: "<item objectid=\"1\"/>"), deflate: true)
        XCTAssertNoThrow(try ThreeMFReader.read(good))
        // Lost end record.
        XCTAssertThrowsError(try ThreeMFReader.read(good.prefix(good.count - 10)))
        XCTAssertThrowsError(try ThreeMFReader.read(good.prefix(good.count / 2)))
        XCTAssertThrowsError(try ThreeMFReader.read(Data("not a zip at all, just text".utf8)))
        XCTAssertThrowsError(try ThreeMFReader.read(Data()))
        // A compressed size running past the end of the file.
        var zip = TestZip()
        zip.items.append(.init(name: "a", data: Data("hello".utf8), declaredCompressed: 5_000))
        let archive = try ZipArchive(zip.build())
        XCTAssertThrowsError(try archive.extract(archive.entries[0], limit: 10_000)) {
            XCTAssertEqual($0 as? ZipArchive.ZipError, .truncated)
        }
        // Damaged contents.
        var bad = TestZip()
        bad.items.append(.init(name: "a", data: Data("hello".utf8), crcOverride: 1234))
        let damaged = try ZipArchive(bad.build())
        XCTAssertThrowsError(try damaged.extract(damaged.entries[0], limit: 100)) {
            XCTAssertEqual($0 as? ZipArchive.ZipError, .corrupt)
        }
    }

    func testCorruptDeflateStreamRejected() throws {
        var zip = TestZip()
        zip.add("a", (0..<2000).map { "\($0 * 7919 % 10007)" }.joined(separator: " "), deflate: true)
        var data = zip.build()
        // Overwrite the middle of the compressed payload (after the 30-byte local header and 1-byte name).
        for offset in 40..<60 { data[offset] = 0xFF }
        let archive = try ZipArchive(data)
        XCTAssertThrowsError(try archive.extract(archive.entries[0], limit: 100_000))
    }

    func testEntryCountAndEncryptionLimits() throws {
        var many = TestZip()
        many.add("a", "x")
        many.declaredEntryCount = UInt16(ZipArchive.maximumEntries + 1)
        XCTAssertThrowsError(try ZipArchive(many.build())) { XCTAssertEqual($0 as? ZipArchive.ZipError, .tooManyEntries) }
        var encrypted = TestZip()
        encrypted.items.append(.init(name: "a", data: Data("x".utf8), flags: 1))
        let archive = try ZipArchive(encrypted.build())
        XCTAssertThrowsError(try archive.extract(archive.entries[0], limit: 10)) { XCTAssertEqual($0 as? ZipArchive.ZipError, .encrypted) }
    }

    // MARK: 3MF

    func testThreeMFSingleObjectStoredAndDeflated() throws {
        let model = modelXML(resources: "<object id=\"1\" type=\"model\">\(cubeMeshXML(size: 10, origin: SIMD3(5, 0, 0)))</object>",
                             build: "<item objectid=\"1\"/>")
        for deflate in [false, true] {
            let parsed = try ThreeMFReader.read(package(model: model, deflate: deflate))
            XCTAssertEqual(parsed.format, .threeMF)
            XCTAssertEqual(parsed.objectCount, 1)
            XCTAssertEqual(parsed.mesh.triangleCount, 12)
            assertClose(parsed.mesh.minimum, SIMD3(5, 0, 0))
            assertClose(parsed.mesh.maximum, SIMD3(15, 10, 10))
            XCTAssertEqual(parsed.partExtents.count, 1)
        }
    }

    func testThreeMFUnitsConvertToMillimetres() throws {
        let expected: [String?: Float] = [nil: 2, "millimeter": 2, "inch": 50.8, "centimeter": 20, "micron": 0.002, "foot": 609.6, "meter": 2000]
        for (unit, size) in expected {
            let model = modelXML(unit: unit, resources: "<object id=\"1\">\(cubeMeshXML(size: 2))</object>", build: "<item objectid=\"1\"/>")
            let parsed = try ThreeMFReader.read(package(model: model))
            assertClose(parsed.mesh.maximum - parsed.mesh.minimum, SIMD3(repeating: size), accuracy: size * 1e-5)
        }
        let furlong = modelXML(unit: "furlong", resources: "<object id=\"1\">\(cubeMeshXML())</object>", build: "<item objectid=\"1\"/>")
        XCTAssertThrowsError(try ThreeMFReader.read(package(model: furlong))) {
            XCTAssertEqual($0 as? ModelFormatError, .unsupportedUnit("furlong"))
        }
    }

    func testThreeMFComponentAndItemTransformsCompose() throws {
        // Object 2 places object 1 twice: shifted by 10 on X, and scaled ×2. The item then moves everything up by 100.
        let resources = """
        <object id="1">\(cubeMeshXML(size: 1))</object>
        <object id="2"><components>
         <component objectid="1" transform="1 0 0 0 1 0 0 0 1 10 0 0"/>
         <component objectid="1" transform="2 0 0 0 2 0 0 0 2 0 0 0"/>
        </components></object>
        """
        let parsed = try ThreeMFReader.read(package(model: modelXML(resources: resources, build: "<item objectid=\"2\" transform=\"1 0 0 0 1 0 0 0 1 0 0 100\"/>")))
        XCTAssertEqual(parsed.mesh.triangleCount, 24)
        XCTAssertEqual(parsed.objectCount, 1)
        assertClose(parsed.mesh.minimum, SIMD3(0, 0, 100))
        assertClose(parsed.mesh.maximum, SIMD3(11, 2, 102))
        // A 90° rotation about Z in 3MF's row-vector form maps +X to +Y.
        let rotated = try ThreeMFReader.read(package(model: modelXML(
            resources: "<object id=\"1\">\(cubeMeshXML(size: 1, origin: SIMD3(1, 0, 0)))</object>",
            build: "<item objectid=\"1\" transform=\"0 1 0 -1 0 0 0 0 1 0 0 0\"/>")))
        assertClose(rotated.mesh.minimum, SIMD3(-1, 1, 0))
        assertClose(rotated.mesh.maximum, SIMD3(0, 2, 1))
    }

    func testAffineComposition() {
        let translate = Affine3D(threeMF: "1 0 0 0 1 0 0 0 1 5 0 0")!
        let scale = Affine3D(threeMF: "2 0 0 0 2 0 0 0 2 0 0 0")!
        // Scale first, then translate.
        XCTAssertEqual(translate.then(scale).apply(SIMD3(1, 1, 1)), SIMD3(7, 2, 2))
        XCTAssertEqual(scale.then(translate).apply(SIMD3(1, 1, 1)), SIMD3(12, 2, 2))
        XCTAssertNil(Affine3D(threeMF: "1 0 0"))
        XCTAssertNil(Affine3D(threeMF: "1 0 0 0 1 0 0 0 1 nan 0 0"))
    }

    func testMirroringTransformKeepsOutwardWinding() throws {
        let resources = "<object id=\"1\">\(cubeMeshXML(size: 1))</object>"
        let plain = try ThreeMFReader.read(package(model: modelXML(resources: resources, build: "<item objectid=\"1\"/>")))
        let mirrored = try ThreeMFReader.read(package(model: modelXML(resources: resources,
                                                                       build: "<item objectid=\"1\" transform=\"-1 0 0 0 1 0 0 0 1 0 0 0\"/>")))
        func signedVolume(_ mesh: STLMesh) -> Float {
            var total: Float = 0
            for i in stride(from: 0, to: mesh.vertices.count, by: 9) {
                let a = SIMD3(mesh.vertices[i], mesh.vertices[i + 1], mesh.vertices[i + 2])
                let b = SIMD3(mesh.vertices[i + 3], mesh.vertices[i + 4], mesh.vertices[i + 5])
                let c = SIMD3(mesh.vertices[i + 6], mesh.vertices[i + 7], mesh.vertices[i + 8])
                total += simd_dot(a, simd_cross(b, c)) / 6
            }
            return total
        }
        XCTAssertEqual(signedVolume(plain.mesh), 1, accuracy: 1e-5)
        XCTAssertEqual(signedVolume(mirrored.mesh), 1, accuracy: 1e-5)
    }

    func testThreeMFMultipleItemsCheckedPerObject() throws {
        // Two 100 mm cubes 300 mm apart: the layout spans 400 mm, but each object fits the build volume.
        let resources = "<object id=\"1\">\(cubeMeshXML(size: 100))</object><object id=\"2\">\(cubeMeshXML(size: 250))</object>"
        let spread = try ThreeMFReader.read(package(model: modelXML(resources: resources, build: """
        <item objectid="1"/><item objectid="1" transform="1 0 0 0 1 0 0 0 1 300 0 0"/>
        """)))
        XCTAssertEqual(spread.objectCount, 2)
        XCTAssertEqual(spread.partExtents.count, 2)
        XCTAssertNil(previewBuildVolumeWarning(spread))
        XCTAssertTrue(previewDimensionsLabel(spread).hasPrefix("Overall 400.0 × 100.0 × 100.0 mm"))
        XCTAssertNotNil(multipleObjectsNotice(objectCount: spread.objectCount))
        let oversized = try ThreeMFReader.read(package(model: modelXML(resources: resources, build: "<item objectid=\"1\"/><item objectid=\"2\"/>")))
        XCTAssertEqual(previewBuildVolumeWarning(oversized), "An object is larger than Slant’s 220 mm build volume")
        let single = try ThreeMFReader.read(package(model: modelXML(resources: resources, build: "<item objectid=\"2\"/>")))
        XCTAssertEqual(previewBuildVolumeWarning(single), "Larger than Slant’s 220 mm build volume")
        XCTAssertNil(multipleObjectsNotice(objectCount: 1))
        XCTAssertEqual(previewDimensionsLabel(single), "250.0 × 250.0 × 250.0 mm")
    }

    func testThreeMFProductionExtensionPaths() throws {
        // Bambu Studio and OrcaSlicer keep meshes in separate parts referenced with p:path.
        let objectPart = modelXML(resources: "<object id=\"7\">\(cubeMeshXML(size: 3))</object>", build: "")
        let root = modelXML(resources: """
        <object id="1"><components><component p:path="/3D/Objects/object_1.model" objectid="7" transform="1 0 0 0 1 0 0 0 1 1 1 1"/></components></object>
        """, build: "<item objectid=\"1\"/>", extraNamespaces: " xmlns:p=\"http://schemas.microsoft.com/3dmanufacturing/production/2015/06\"")
        let parsed = try ThreeMFReader.read(package(model: root, deflate: true, extra: [("3D/Objects/object_1.model", objectPart)]))
        XCTAssertEqual(parsed.mesh.triangleCount, 12)
        assertClose(parsed.mesh.minimum, SIMD3(1, 1, 1))
        assertClose(parsed.mesh.maximum, SIMD3(4, 4, 4))
        // A missing referenced part is an error, not an empty preview.
        XCTAssertThrowsError(try ThreeMFReader.read(package(model: root)))
    }

    func testThreeMFStructuralErrors() {
        let mesh = "<object id=\"1\">\(cubeMeshXML())</object>"
        // Missing model part.
        var noModel = TestZip()
        noModel.add("_rels/.rels", threeMFRels)
        XCTAssertThrowsError(try ThreeMFReader.read(noModel.build())) { XCTAssertEqual($0 as? ModelFormatError, .missingModel) }
        // Missing relationships fall back to the conventional part name.
        var noRels = TestZip()
        noRels.add("3D/3dmodel.model", modelXML(resources: mesh, build: "<item objectid=\"1\"/>"))
        XCTAssertNoThrow(try ThreeMFReader.read(noRels.build()))
        XCTAssertThrowsError(try ThreeMFReader.read(package(model: modelXML(resources: mesh, build: "")))) {
            XCTAssertEqual($0 as? ModelFormatError, .noBuildItems)
        }
        XCTAssertThrowsError(try ThreeMFReader.read(package(model: modelXML(resources: mesh, build: "<item objectid=\"9\"/>")))) {
            XCTAssertEqual($0 as? ModelFormatError, .missingObject(9))
        }
        let badIndex = mesh.replacingOccurrences(of: "v3=\"3\"", with: "v3=\"99\"")
        XCTAssertThrowsError(try ThreeMFReader.read(package(model: modelXML(resources: badIndex, build: "<item objectid=\"1\"/>"))))
        let badNumber = mesh.replacingOccurrences(of: "x=\"1.0\"", with: "x=\"abc\"")
        XCTAssertThrowsError(try ThreeMFReader.read(package(model: modelXML(resources: badNumber, build: "<item objectid=\"1\"/>"))))
        XCTAssertThrowsError(try ThreeMFReader.read(package(model: "<model><resources>")))
        // Self-referencing components are cut off rather than recursing forever.
        let cycle = "<object id=\"1\"><components><component objectid=\"1\"/></components></object>"
        XCTAssertThrowsError(try ThreeMFReader.read(package(model: modelXML(resources: cycle, build: "<item objectid=\"1\"/>")))) {
            XCTAssertEqual($0 as? ModelFormatError, .tooDeep)
        }
        // Entity declarations (billion-laughs style) are refused.
        let entities = "<?xml version=\"1.0\"?><!DOCTYPE model [<!ENTITY a \"aaaa\">]>" + modelXML(resources: mesh, build: "<item objectid=\"1\"/>")
            .replacingOccurrences(of: "<?xml version=\"1.0\" encoding=\"UTF-8\"?>", with: "")
        XCTAssertThrowsError(try ThreeMFReader.read(package(model: entities)))
    }

    func testThreeMFInstanceExpansionIsCapped() throws {
        // 12 triangles instanced 45,000 times would exceed the 500,000-triangle preview limit.
        let components = String(repeating: "<component objectid=\"1\"/>", count: 45_000)
        let resources = "<object id=\"1\">\(cubeMeshXML())</object><object id=\"2\"><components>\(components)</components></object>"
        XCTAssertThrowsError(try ThreeMFReader.read(package(model: modelXML(resources: resources, build: "<item objectid=\"2\"/>")))) {
            guard case STLMesh.ParseError.oversized = $0 else { return XCTFail("Unexpected error: \($0)") }
        }
    }

    func testNestedInstancingCannotOverflowOrHang() throws {
        // Ten levels of ten copies would place 12 × 10¹⁰ triangles; the count saturates instead of overflowing.
        var resources = "<object id=\"0\">\(cubeMeshXML())</object>"
        for level in 1...10 {
            resources += "<object id=\"\(level)\"><components>" + String(repeating: "<component objectid=\"\(level - 1)\"/>", count: 10) + "</components></object>"
        }
        XCTAssertThrowsError(try ThreeMFReader.read(package(model: modelXML(resources: resources, build: "<item objectid=\"10\"/>")))) {
            guard case STLMesh.ParseError.oversized = $0 else { return XCTFail("Unexpected error: \($0)") }
        }
        // Doubling empty objects 30 levels deep has no triangles to count, so the walk itself is capped.
        var empty = "<object id=\"0\"><components></components></object><object id=\"100\">\(cubeMeshXML())</object>"
        for level in 1...30 {
            empty += "<object id=\"\(level)\"><components><component objectid=\"\(level - 1)\"/><component objectid=\"\(level - 1)\"/></components></object>"
        }
        XCTAssertThrowsError(try ThreeMFReader.read(package(model: modelXML(resources: empty, build: "<item objectid=\"100\"/><item objectid=\"30\"/>")))) {
            guard case STLMesh.ParseError.oversized = $0 else { return XCTFail("Unexpected error: \($0)") }
        }
    }

    func testRealSlicerExportIfInstalled() throws {
        let sample = URL(fileURLWithPath: "/Applications/OrcaSlicer.app/Contents/Resources/handy_models/OrcaSliced.3mf")
        guard FileManager.default.fileExists(atPath: sample.path) else { throw XCTSkip("OrcaSlicer sample not installed") }
        let parsed = try loadPreviewModel(from: sample)
        XCTAssertGreaterThan(parsed.mesh.triangleCount, 1000)
        XCTAssertEqual(parsed.objectCount, parsed.partExtents.count)
    }

    // MARK: OBJ

    func testOBJQuadsNegativeIndicesAndVertexForms() throws {
        let source = """
        # exported
        mtllib part.mtl
        o Part
        v 0 0 0
        v 10 0 0
        v 10 10 0
        v 0 10 0
        vt 0 0
        vn 0 0 1
        usemtl Plastic
        s off
        f 1/1/1 2/1/1 3/1/1 4/1/1
        v 0 0 5 1.0 0.5 0.5
        f -4//1 -3//1 -1//1
        f 2/1 3/1 5/1
        l 1 2
        """
        let mesh = try OBJParser.parse(Data(source.utf8))
        XCTAssertEqual(mesh.triangleCount, 4)
        XCTAssertEqual(Array(mesh.vertices.prefix(18)), [0, 0, 0, 10, 0, 0, 10, 10, 0, 0, 0, 0, 10, 10, 0, 0, 10, 0])
        // -4, -3, -1 with five vertices defined refer to vertices 2, 3 and 5.
        XCTAssertEqual(Array(mesh.vertices[18..<27]), [10, 0, 0, 10, 10, 0, 0, 0, 5])
        XCTAssertEqual(mesh.minimum, SIMD3(0, 0, 0))
        XCTAssertEqual(mesh.maximum, SIMD3(10, 10, 5))
    }

    func testOBJPolygonFanAndContinuation() throws {
        let source = "v 0 0 0\nv 2 0 0\nv 3 1 0\nv 1 2 1\nv -1 1 0\nf 1 2 3 \\\n 4 5\r\n"
        let mesh = try OBJParser.parse(Data(source.utf8))
        XCTAssertEqual(mesh.triangleCount, 3)
        XCTAssertEqual(Array(mesh.vertices[18..<27]), [0, 0, 0, 1, 2, 1, -1, 1, 0])
    }

    func testOBJRejectsBadInput() {
        let cases = [
            "v 0 0 0\nv 1 0 0\nv 0 1 0\nf 1 2 0",      // zero index
            "v 0 0 0\nv 1 0 0\nv 0 1 0\nf 1 2 4",      // past the end
            "v 0 0 0\nv 1 0 0\nv 0 1 0\nf 1 -4 2",     // before the start
            "v 0 0 0\nv 1 0 0\nf 1 2",                 // fewer than three corners
            "v 0 0\nf 1 1 1",                          // short vertex
            "v 0 nan 0\nv 1 0 0\nv 0 1 1\nf 1 2 3",    // non-finite
            "v 0 0 0\nv 1 0 0\nv 0 1 1\nf 1 2 x",      // not a number
            "v 0 0 0\nv 1 0 0\nv 0 1 0",               // no faces
            "",
            "v 0 0 0\nv 1 1 1\nv 2 2 2\n" + "f " + String(repeating: "1 ", count: 40_000) // line too long
        ]
        for source in cases {
            XCTAssertThrowsError(try OBJParser.parse(Data(source.utf8)), source.prefix(40).description)
        }
        XCTAssertThrowsError(try OBJParser.parse(Data("v 0 0 0\nv 1 0 0\nf 1 2 3".utf8))) {
            XCTAssertEqual($0 as? ModelFormatError, .obj(line: 3, reason: "face refers to a missing vertex"))
        }
    }

    // MARK: Integration helpers

    func testLoaderDispatchAndFileLimits() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let obj = folder.appendingPathComponent("part.OBJ")
        try Data("v 0 0 0\nv 1 0 0\nv 0 1 1\nf 1 2 3\n".utf8).write(to: obj)
        XCTAssertEqual(try loadPreviewModel(from: obj).format, .obj)
        let threeMF = folder.appendingPathComponent("part.3mf")
        try package(model: modelXML(resources: "<object id=\"1\">\(cubeMeshXML())</object>", build: "<item objectid=\"1\"/>")).write(to: threeMF)
        XCTAssertEqual(try loadPreviewModel(from: threeMF).mesh.triangleCount, 12)
        XCTAssertThrowsError(try loadPreviewModel(from: folder.appendingPathComponent("part.step")))
        // A renamed non-ZIP file reports a clear error.
        let fake = folder.appendingPathComponent("fake.3mf")
        try Data("solid not really".utf8).write(to: fake)
        XCTAssertThrowsError(try loadPreviewModel(from: fake))
        XCTAssertTrue(supportsLocalPreview(threeMF))
        XCTAssertFalse(supportsLocalPreview(folder.appendingPathComponent("part.step")))
    }

    func testScaleWarningFollowsFormatUnits() {
        let tiny = SIMD3<Float>(2, 1, 0.5)
        XCTAssertTrue(scaleWarning(extentMM: tiny, fileExtension: "stl")!.message.contains("STL files don’t record units"))
        XCTAssertTrue(scaleWarning(extentMM: tiny, fileExtension: "OBJ")!.message.contains("OBJ files don’t record units"))
        XCTAssertNil(scaleWarning(extentMM: tiny, fileExtension: "3mf"))
        XCTAssertEqual(scaleWarning(extentMM: tiny, fileExtension: "obj")?.suggestions, scaleWarning(extentMM: tiny)?.suggestions)
    }

    func testLocalModelPreviewAndToolSupport() {
        for (path, preview, tools) in [("/tmp/a.stl", true, true), ("/tmp/a.obj", true, false), ("/tmp/a.3MF", true, false), ("/tmp/a.step", false, false)] {
            let model = LocalModel(name: "a", filePath: path)
            XCTAssertEqual(model.supportsMeshPreview, preview, path)
            XCTAssertEqual(model.supportsPreview, tools, path)
        }
    }

    func testSTLCopyKeepsGeometry() throws {
        let source = try OBJParser.parse(Data("v 0 0 0\nv 4 0 0\nv 4 3 0\nv 0 3 2\nf 1 2 3 4\n".utf8))
        let copy = try STLMesh.parse(source.stlCopyData())
        XCTAssertEqual(copy.vertices, source.vertices)
        XCTAssertEqual(copy.minimum, source.minimum)
        XCTAssertEqual(copy.maximum, source.maximum)
        XCTAssertEqual(stlCopyName("bracket.3mf"), "bracket (STL copy)")
        XCTAssertEqual(stlCopyName("bracket"), "bracket (STL copy)")
        XCTAssertEqual(stlCopyName("v1.2"), "v1.2 (STL copy)")
    }

    // MARK: Finder opens

    func testFinderOpensAreFilteredAndDeduplicated() {
        let a = URL(fileURLWithPath: "/tmp/a.stl")
        let b = URL(fileURLWithPath: "/tmp/sub/../b.3MF")
        let queued = queuedModelOpens([a], adding: [a, b, URL(fileURLWithPath: "/tmp/b.3MF"), URL(fileURLWithPath: "/tmp/notes.txt"),
                                                    URL(string: "https://example.com/c.obj")!, URL(fileURLWithPath: "/tmp/c.obj")])
        XCTAssertEqual(queued.map(\.lastPathComponent), ["a.stl", "b.3MF", "c.obj"])
    }

    func testFinderOpensWaitForModalUIAndRequests() {
        XCTAssertTrue(externalOpenCanImport(storeSheetPresented: false, appModalUIPresented: false, errorShown: false, busy: false))
        XCTAssertFalse(externalOpenCanImport(storeSheetPresented: true, appModalUIPresented: false, errorShown: false, busy: false))
        // A Pay or Cancel review is a SwiftUI sheet the store doesn't track; AppKit's modal state covers it.
        XCTAssertFalse(externalOpenCanImport(storeSheetPresented: false, appModalUIPresented: true, errorShown: false, busy: false))
        XCTAssertFalse(externalOpenCanImport(storeSheetPresented: false, appModalUIPresented: false, errorShown: true, busy: false))
        XCTAssertFalse(externalOpenCanImport(storeSheetPresented: false, appModalUIPresented: false, errorShown: false, busy: true))
    }
}

// MARK: - OBJ face triangulation

extension ModelFormatsTests {
    private func triangulate(_ points: [SIMD3<Float>], workLimit: Int = .max) -> (indices: [Int], exact: Bool) {
        var work = 0
        return triangulateOBJFace(points, work: &work, workLimit: workLimit)
    }

    private func flat(_ xy: [(Float, Float)]) -> [SIMD3<Float>] { xy.map { SIMD3($0.0, $0.1, 0) } }

    /// Signed area in the XY plane (positive counter-clockwise).
    private func signedArea(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>) -> Double {
        Double((b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x)) / 2
    }

    private func polygonArea(_ points: [SIMD3<Float>]) -> Double {
        var twice = 0.0
        for i in points.indices {
            let a = points[i], b = points[(i + 1) % points.count]
            twice += Double(a.x * b.y - b.x * a.y)
        }
        return twice / 2
    }

    /// Even-odd point-in-polygon test in the XY plane (points on the boundary may go either way).
    private func contains(_ polygon: [SIMD3<Float>], _ q: SIMD2<Double>) -> Bool {
        var inside = false
        var j = polygon.count - 1
        for i in polygon.indices {
            let a = SIMD2<Double>(Double(polygon[i].x), Double(polygon[i].y))
            let b = SIMD2<Double>(Double(polygon[j].x), Double(polygon[j].y))
            if (a.y > q.y) != (b.y > q.y), q.x < (b.x - a.x) * (q.y - a.y) / (b.y - a.y) + a.x { inside.toggle() }
            j = i
        }
        return inside
    }

    /// Checks a planar XY triangulation: every triangle keeps the polygon's winding, the areas add up to the polygon's,
    /// and no triangle with area has its centroid outside the polygon.
    private func assertTriangulationCovers(_ polygon: [SIMD3<Float>], _ indices: [Int], file: StaticString = #filePath, line: UInt = #line) {
        let area = polygonArea(polygon)
        XCTAssertEqual(indices.count % 3, 0, file: file, line: line)
        var sum = 0.0
        for t in stride(from: 0, to: indices.count, by: 3) {
            let a = polygon[indices[t]], b = polygon[indices[t + 1]], c = polygon[indices[t + 2]]
            let triangle = signedArea(a, b, c)
            XCTAssertGreaterThanOrEqual(area < 0 ? -triangle : triangle, -1e-9, "triangle \(t / 3) is wound the wrong way", file: file, line: line)
            sum += triangle
            guard abs(triangle) > 1e-9 else { continue }
            let centroid = SIMD2<Double>(Double(a.x + b.x + c.x) / 3, Double(a.y + b.y + c.y) / 3)
            XCTAssertTrue(contains(polygon, centroid), "triangle \(t / 3) lies outside the face", file: file, line: line)
        }
        XCTAssertEqual(sum, area, accuracy: 1e-6, file: file, line: line)
    }

    private func rotations<T>(_ items: [T]) -> [[T]] {
        items.indices.map { Array(items[$0...] + items[..<$0]) }
    }

    func testConvexQuadIsTheSameFanAsBefore() {
        let square = flat([(0, 0), (2, 0), (2, 2), (0, 2)])
        let result = triangulate(square)
        XCTAssertTrue(result.exact)
        XCTAssertEqual(result.indices, [0, 1, 2, 0, 2, 3])
        // A slightly warped (non-planar) convex quad is still fanned.
        let warped = [SIMD3<Float>(0, 0, 0), SIMD3(4, 0, 0), SIMD3(4, 3, 0), SIMD3(0, 3, 2)]
        XCTAssertEqual(triangulate(warped).indices, [0, 1, 2, 0, 2, 3])
        XCTAssertEqual(triangulate(flat([(0, 0), (1, 0), (0, 1)])).indices, [0, 1, 2])
    }

    func testConcaveLHexagonIsEarClippedInsideTheFace() {
        let l = flat([(0, 0), (2, 0), (2, 1), (1, 1), (1, 2), (0, 2)])
        for (index, polygon) in rotations(l).enumerated() {
            for winding in [polygon, Array(polygon.reversed())] {
                let result = triangulate(winding)
                XCTAssertTrue(result.exact, "rotation \(index)")
                XCTAssertEqual(result.indices.count, 12, "rotation \(index)")
                assertTriangulationCovers(winding, result.indices)
            }
        }
        // Starting at (2, 1), the old fan from the first corner put a triangle outside the L.
        let start = flat([(2, 1), (1, 1), (1, 2), (0, 2), (0, 0), (2, 0)])
        let oldFan = (1..<5).flatMap { [0, $0, $0 + 1] }
        let outside = stride(from: 0, to: oldFan.count, by: 3).contains { t in
            let a = start[oldFan[t]], b = start[oldFan[t + 1]], c = start[oldFan[t + 2]]
            return !contains(start, SIMD2(Double(a.x + b.x + c.x) / 3, Double(a.y + b.y + c.y) / 3))
        }
        XCTAssertTrue(outside, "the fixture must defeat a fan")
    }

    func testWindingIsPreservedForBothOrientations() {
        let l = flat([(2, 1), (1, 1), (1, 2), (0, 2), (0, 0), (2, 0)])
        for polygon in [l, Array(l.reversed())] {
            let expected = polygonArea(polygon).sign
            let result = triangulate(polygon)
            for t in stride(from: 0, to: result.indices.count, by: 3) {
                let area = signedArea(polygon[result.indices[t]], polygon[result.indices[t + 1]], polygon[result.indices[t + 2]])
                XCTAssertEqual(area.sign, expected)
            }
        }
    }

    func testTiltedConcaveFaceUsesItsOwnPlane() {
        // The L lifted onto the plane z = x + y: projected to XY it is the same L, so XY checks still apply.
        let l = [(2, 1), (1, 1), (1, 2), (0, 2), (0, 0), (2, 0)].map { SIMD3<Float>(Float($0.0), Float($0.1), Float($0.0 + $0.1)) }
        let result = triangulate(l)
        XCTAssertTrue(result.exact)
        assertTriangulationCovers(l.map { SIMD3($0.x, $0.y, 0) }, result.indices)
    }

    func testCollinearCornersStayExactAndClosed() {
        // Midpoint on an edge of a convex face: still the plain fan.
        let square = flat([(0, 0), (1, 0), (2, 0), (2, 2), (0, 2)])
        let convex = triangulate(square)
        XCTAssertTrue(convex.exact)
        assertTriangulationCovers(square, convex.indices)
        // Concave face with a corner on a straight edge.
        let l = flat([(1, 1), (1, 2), (0, 2), (0, 1), (0, 0), (2, 0), (2, 1)])
        for polygon in rotations(l) {
            let result = triangulate(polygon)
            XCTAssertTrue(result.exact)
            assertTriangulationCovers(polygon, result.indices)
        }
        // Every corner on one line: no area to split, so the fan (all zero-area) is exact.
        let line = flat([(0, 0), (1, 0), (2, 0), (3, 0)])
        let degenerate = triangulate(line)
        XCTAssertTrue(degenerate.exact)
        XCTAssertEqual(degenerate.indices, [0, 1, 2, 0, 2, 3])
        // Repeated corners are skipped.
        let repeated = flat([(2, 1), (1, 1), (1, 1), (1, 2), (0, 2), (0, 0), (2, 0), (2, 1)])
        let result = triangulate(repeated)
        XCTAssertTrue(result.exact)
        assertTriangulationCovers(repeated, result.indices)
    }

    func testLargeConcaveCombIsExactAndBounded() {
        var comb: [SIMD3<Float>] = []
        for i in 0..<60 { comb += [SIMD3(Float(i) * 2, 0, 0), SIMD3(Float(i) * 2 + 1, 10, 0)] }
        comb += [SIMD3(120, 0, 0), SIMD3(120, -5, 0), SIMD3(0, -5, 0)]
        var work = 0
        let result = triangulateOBJFace(comb, work: &work)
        XCTAssertTrue(result.exact)
        XCTAssertEqual(result.indices.count, 3 * (comb.count - 2))
        assertTriangulationCovers(comb, result.indices)
        // The same face over a small budget is reported, not stalled on.
        var small = 0
        XCTAssertFalse(triangulateOBJFace(comb, work: &small, workLimit: 50).exact)
        XCTAssertLessThanOrEqual(small, 52)
    }

    func testSelfIntersectingFacesAreFannedAndReportedInexact() {
        let bowTie = flat([(0, 0), (2, 2), (2, 0), (0, 2)])
        let tie = triangulate(bowTie)
        XCTAssertFalse(tie.exact)
        XCTAssertEqual(tie.indices, [0, 1, 2, 0, 2, 3])
        let star = flat([(0, 3), (2, -3), (-3, 1), (3, 1), (-2, -3)])
        XCTAssertFalse(triangulate(star).exact)
        // A concave face that touches itself at a corner.
        let touching = flat([(0, 0), (4, 0), (4, 4), (2, 0), (0, 4)])
        XCTAssertFalse(triangulate(touching).exact)
        // Running out of work is reported the same way.
        let l = flat([(2, 1), (1, 1), (1, 2), (0, 2), (0, 0), (2, 0)])
        XCTAssertFalse(triangulate(l, workLimit: 3).exact)
    }

    func testOBJReportsInexactFacesAndRefusesCopies() throws {
        let concave = "v 2 1 0\nv 1 1 0\nv 1 2 0\nv 0 2 0\nv 0 0 0\nv 2 0 0\nf 1 2 3 4 5 6\n"
        let good = try OBJParser.parseWithReport(Data(concave.utf8))
        XCTAssertEqual(good.inexactFaces, 0)
        XCTAssertEqual(good.mesh.triangleCount, 4)
        let preview = try parsePreviewModel(Data(concave.utf8), format: .obj)
        XCTAssertEqual(preview.inexactFaces, 0)
        XCTAssertNil(stlCopyBlockedReason(format: .obj, inexactFaces: preview.inexactFaces))

        let crossed = "v 0 0 0\nv 2 2 0\nv 2 0 0\nv 0 2 0\nv 0 0 1\nf 1 2 3 4\nf 1 3 5\n"
        let broken = try parsePreviewModel(Data(crossed.utf8), format: .obj)
        XCTAssertEqual(broken.inexactFaces, 1)
        XCTAssertEqual(broken.mesh.triangleCount, 3, "still previewed as a fan")
        let reason = try XCTUnwrap(stlCopyBlockedReason(format: .obj, inexactFaces: broken.inexactFaces))
        XCTAssertTrue(reason.hasPrefix("This OBJ has a face that can’t be split into triangles exactly"))
        XCTAssertTrue(stlCopyBlockedReason(format: .obj, inexactFaces: 3)!.contains("3 faces"))
    }

    func testFormatErrorsNameTheFormat() {
        func message(_ body: () throws -> Any) -> String {
            do { _ = try body(); return "" } catch { return error.localizedDescription }
        }
        let noFaces = message { try OBJParser.parse(Data("v 0 0 0\nv 1 0 0\nv 0 1 0".utf8)) }
        XCTAssertEqual(noFaces, "This OBJ doesn’t contain any triangles.")
        let onePoint = message { try OBJParser.parse(Data("v 1 1 1\nf 1 1 1".utf8)) }
        XCTAssertEqual(onePoint, "This OBJ contains invalid coordinates, or its triangles have no size.")
        let empty3MF = message {
            try ThreeMFReader.read(package(model: modelXML(resources: "<object id=\"1\"><mesh><vertices/><triangles/></mesh></object>",
                                                           build: "<item objectid=\"1\"/>")))
        }
        XCTAssertEqual(empty3MF, "This 3MF doesn’t contain any triangles.")
        let unknown = message { try loadPreviewModel(from: URL(fileURLWithPath: "/tmp/part.step")) }
        XCTAssertEqual(unknown, unsupportedPreviewMessage)
        for text in [noFaces, onePoint, empty3MF] { XCTAssertFalse(text.contains("STL"), text) }
        // STL keeps its own wording.
        XCTAssertTrue(message { try STLMesh.parse(Data("solid x\nendsolid x".utf8)) }.contains("STL"))
    }

    func testMultipleObjectsNoticeWording() {
        XCTAssertEqual(multipleObjectsNotice(objectCount: 3), "This file places 3 objects. Uploading sends the whole file — check the estimate covers them all.")
    }

    // MARK: 3MF hardening

    func testZipLookupUsesIndexWithSameRules() throws {
        var zip = TestZip()
        zip.add("3D/Model.model", "a")
        zip.add("3D/model.model", "b")
        zip.add("3d/MODEL.MODEL", "c")
        let archive = try ZipArchive(zip.build())
        XCTAssertEqual(archive.entry(named: "/3D/model.model")?.name, "3D/model.model", "exact match wins")
        XCTAssertEqual(archive.entry(named: "3D/MODEL.model")?.name, "3D/Model.model", "first case-insensitive match")
        XCTAssertNil(archive.entry(named: "3D/other.model"))
    }

    func testThreeMFComponentFloodIsCappedInTheCountingPass() throws {
        // 120,000 empty components through a separate model part, in a package with thousands of other entries.
        // The reference differs in case from the entry, the slow path for a linear name search.
        let components = String(repeating: "<component objectid=\"1\" p:path=\"/3d/objects/PART.model\"/>", count: 120_000)
        let root = modelXML(resources: "<object id=\"2\"><components>\(components)</components></object>", build: "<item objectid=\"2\"/>",
                            extraNamespaces: " xmlns:p=\"http://schemas.microsoft.com/3dmanufacturing/production/2015/06\"")
        let part = modelXML(resources: "<object id=\"1\"><mesh><vertices/><triangles/></mesh></object>", build: "")
        var extra = (0..<3_000).map { ("Metadata/thumb\($0).png", "x") }
        extra.append(("3D/Objects/part.model", part))
        let started = Date()
        XCTAssertThrowsError(try ThreeMFReader.read(package(model: root, extra: extra))) {
            guard case STLMesh.ParseError.oversized = $0 else { return XCTFail("Unexpected error: \($0)") }
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 30, "bounded work")
    }

    func testDocumentTypesAreRefusedInAnyEncodingOrPosition() throws {
        let mesh = "<object id=\"1\">\(cubeMeshXML())</object>"
        let body = modelXML(resources: mesh, build: "<item objectid=\"1\"/>")
            .replacingOccurrences(of: "<?xml version=\"1.0\" encoding=\"UTF-8\"?>", with: "")
        // UTF-16 little-endian with a byte order mark, which a UTF-8 byte scan alone would miss.
        let utf16 = "<?xml version=\"1.0\" encoding=\"UTF-16\"?><!DOCTYPE model [<!ENTITY a \"aaaa\">]>" + body
        var zip = TestZip()
        zip.add("_rels/.rels", threeMFRels)
        zip.items.append(TestZip.Item(name: "3D/3dmodel.model", data: Data([0xFF, 0xFE]) + utf16.data(using: .utf16LittleEndian)!))
        XCTAssertThrowsError(try ThreeMFReader.read(zip.build()))
        // A DTD after a long comment is past the byte scan; the parser callback still refuses it.
        let late = "<?xml version=\"1.0\"?><!--" + String(repeating: "x", count: 70_000) + "--><!DOCTYPE model [<!ENTITY a \"aaaa\">]>" + body
        XCTAssertThrowsError(try ThreeMFReader.read(package(model: late))) {
            XCTAssertEqual($0 as? ModelFormatError, .invalid3MF("it contains a document type declaration"))
        }
        // The same model without a DTD reads normally.
        XCTAssertEqual(try ThreeMFReader.read(package(model: body)).mesh.triangleCount, 12)
    }

    // MARK: STL-only tools and Finder queue

    func testSTLOnlyToolCopyAndQueueNotes() {
        XCTAssertNil(stlOnlyToolNote(LocalModel(name: "a", filePath: "/tmp/a.stl")))
        XCTAssertNil(stlOnlyToolNote(LocalModel(name: "a", filePath: "/tmp/a.obj")), "OBJ and 3MF share one notice")
        XCTAssertNil(stlOnlyToolNote(LocalModel(name: "a", filePath: "/tmp/a.3mf")))
        XCTAssertEqual(stlOnlyToolNote(LocalModel(name: "a", filePath: "/tmp/a.step")), "Available for STL files.")
        XCTAssertTrue(scaledCopyExplanation(format: .obj).contains("The copy is an STL file."))
        XCTAssertFalse(scaledCopyExplanation(format: .stl).contains("STL file"))
        XCTAssertNil(queuedImportNote(count: 0))
        XCTAssertEqual(queuedImportNote(count: 1), "1 file waiting to import")
        XCTAssertEqual(queuedImportNote(count: 3), "3 files waiting to import")
    }
}
