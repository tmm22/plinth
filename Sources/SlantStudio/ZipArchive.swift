import Foundation
import Compression

/// A minimal read-only ZIP reader for 3MF packages: central directory (including ZIP64), stored and DEFLATE entries.
/// Every size in the archive is untrusted, so extraction is bounded by an explicit budget and a compression-ratio cap.
struct ZipArchive {
    struct Entry: Equatable {
        let name: String
        let method: UInt16
        let flags: UInt16
        let crc32: UInt32
        let compressedSize: Int
        let uncompressedSize: Int
        let localHeaderOffset: Int
        var isDirectory: Bool { name.hasSuffix("/") }
    }

    enum ZipError: LocalizedError, Equatable {
        case notAnArchive, truncated, tooManyEntries, unsupportedCompression, encrypted, oversized, suspiciousRatio, corrupt
        var errorDescription: String? {
            switch self {
            case .notAnArchive: return "This 3MF isn’t a valid ZIP package."
            case .truncated: return "This 3MF package is incomplete or damaged."
            case .tooManyEntries: return "This 3MF package contains too many files to preview."
            case .unsupportedCompression: return "This 3MF uses a compression method the preview doesn’t support."
            case .encrypted: return "This 3MF is encrypted, so it can’t be previewed."
            case .oversized: return "This 3MF expands beyond the preview limit of 128 MB."
            case .suspiciousRatio: return "This 3MF expands far more than a model file should, so it wasn’t opened."
            case .corrupt: return "Part of this 3MF package is damaged."
            }
        }
    }

    static let maximumEntries = 10_000
    /// Entries larger than this must not expand more than `maximumRatio` times their compressed size. DEFLATE can reach
    /// about 1,000:1; model XML typically compresses 3–20:1.
    static let ratioCheckThreshold = 1_000_000
    static let maximumRatio = 200

    let data: Data
    let entries: [Entry]
    /// Entry positions by exact and by lower-cased name, built once so each lookup is constant time. Where names
    /// repeat, the first entry in directory order wins, as a linear search would.
    private let exactIndex: [String: Int]
    private let foldedIndex: [String: Int]

    init(_ data: Data) throws {
        self.data = data
        let entries = try Self.readCentralDirectory(data)
        self.entries = entries
        var exact: [String: Int] = [:], folded: [String: Int] = [:]
        exact.reserveCapacity(entries.count)
        folded.reserveCapacity(entries.count)
        for (position, entry) in entries.enumerated() {
            if exact[entry.name] == nil { exact[entry.name] = position }
            let lowered = entry.name.lowercased()
            if folded[lowered] == nil { folded[lowered] = position }
        }
        exactIndex = exact
        foldedIndex = folded
    }

    /// Looks up an entry by its part name. A leading "/" is ignored; an exact match wins over a case-insensitive one.
    func entry(named name: String) -> Entry? {
        let wanted = name.hasPrefix("/") ? String(name.dropFirst()) : name
        if let position = exactIndex[wanted] ?? foldedIndex[wanted.lowercased()] { return entries[position] }
        return nil
    }

    /// Extracts an entry whose declared uncompressed size is at most `limit` bytes, verifying its size and CRC-32.
    func extract(_ entry: Entry, limit: Int) throws -> Data {
        guard entry.flags & 1 == 0 else { throw ZipError.encrypted }
        guard entry.uncompressedSize <= limit else { throw ZipError.oversized }
        if entry.uncompressedSize > Self.ratioCheckThreshold,
           entry.uncompressedSize / max(entry.compressedSize, 1) > Self.maximumRatio {
            throw ZipError.suspiciousRatio
        }
        let header = entry.localHeaderOffset
        guard header >= 0, header <= data.count - 30, readUInt32(data, header) == 0x04034b50 else { throw ZipError.corrupt }
        let start = header + 30 + Int(readUInt16(data, header + 26)) + Int(readUInt16(data, header + 28))
        guard start <= data.count, entry.compressedSize <= data.count - start else { throw ZipError.truncated }
        let source = data.subdata(in: (data.startIndex + start)..<(data.startIndex + start + entry.compressedSize))
        let output: Data
        switch entry.method {
        case 0:
            guard entry.compressedSize == entry.uncompressedSize else { throw ZipError.corrupt }
            output = source
        case 8:
            output = try Self.inflate(source, expectedSize: entry.uncompressedSize)
        default:
            throw ZipError.unsupportedCompression
        }
        guard zipCRC32(output) == entry.crc32 else { throw ZipError.corrupt }
        return output
    }

    /// Raw DEFLATE (Compression's COMPRESSION_ZLIB has no zlib header). One spare byte detects output beyond the declared size.
    private static func inflate(_ source: Data, expectedSize: Int) throws -> Data {
        if expectedSize == 0 { return Data() }
        guard !source.isEmpty else { throw ZipError.truncated }
        let capacity = expectedSize + 1
        var output = Data(count: capacity)
        let written = output.withUnsafeMutableBytes { (destination: UnsafeMutableRawBufferPointer) -> Int in
            source.withUnsafeBytes { (input: UnsafeRawBufferPointer) -> Int in
                guard let out = destination.bindMemory(to: UInt8.self).baseAddress,
                      let src = input.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return compression_decode_buffer(out, capacity, src, input.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard written == expectedSize else { throw written > expectedSize ? ZipError.corrupt : ZipError.truncated }
        output.removeLast()
        return output
    }

    private static func readCentralDirectory(_ data: Data) throws -> [Entry] {
        guard data.count >= 22 else { throw ZipError.notAnArchive }
        // The end-of-central-directory record sits in the last 22 + 65,535 (maximum comment) bytes.
        var eocd: Int?
        var position = data.count - 22
        let lowest = max(0, data.count - 22 - 65_535)
        while position >= lowest {
            if readUInt32(data, position) == 0x06054b50 { eocd = position; break }
            position -= 1
        }
        guard let end = eocd else { throw ZipError.notAnArchive }
        guard readUInt16(data, end + 4) == 0, readUInt16(data, end + 6) == 0 else { throw ZipError.notAnArchive }
        var count = Int(readUInt16(data, end + 10))
        var directorySize = Int(readUInt32(data, end + 12))
        var directoryOffset = Int(readUInt32(data, end + 16))
        var directoryLimit = end
        if count == 0xFFFF || directorySize == 0xFFFF_FFFF || directoryOffset == 0xFFFF_FFFF {
            // ZIP64: a 20-byte locator precedes the classic record and points at the ZIP64 end record.
            let locator = end - 20
            guard locator >= 0, readUInt32(data, locator) == 0x07064b50 else { throw ZipError.notAnArchive }
            guard let record = Int(exactly: readUInt64(data, locator + 8)), record >= 0, record <= locator - 56,
                  readUInt32(data, record) == 0x06064b50 else { throw ZipError.truncated }
            guard let total = Int(exactly: readUInt64(data, record + 32)),
                  let size = Int(exactly: readUInt64(data, record + 40)),
                  let offset = Int(exactly: readUInt64(data, record + 48)) else { throw ZipError.truncated }
            count = total
            directorySize = size
            directoryOffset = offset
            directoryLimit = record
        }
        guard count <= maximumEntries else { throw ZipError.tooManyEntries }
        guard directoryOffset >= 0, directorySize >= 0, directoryOffset <= directoryLimit,
              directorySize <= directoryLimit - directoryOffset else { throw ZipError.truncated }

        var entries: [Entry] = []
        entries.reserveCapacity(count)
        var cursor = directoryOffset
        let directoryEnd = directoryOffset + directorySize
        for _ in 0..<count {
            guard cursor <= directoryEnd - 46, readUInt32(data, cursor) == 0x02014b50 else { throw ZipError.truncated }
            let flags = readUInt16(data, cursor + 8)
            let method = readUInt16(data, cursor + 10)
            let crc = readUInt32(data, cursor + 16)
            var compressed = UInt64(readUInt32(data, cursor + 20))
            var uncompressed = UInt64(readUInt32(data, cursor + 24))
            let nameLength = Int(readUInt16(data, cursor + 28))
            let extraLength = Int(readUInt16(data, cursor + 30))
            let commentLength = Int(readUInt16(data, cursor + 32))
            var offset = UInt64(readUInt32(data, cursor + 42))
            let nameStart = cursor + 46
            let extraStart = nameStart + nameLength
            let next = extraStart + extraLength + commentLength
            guard next <= directoryEnd else { throw ZipError.truncated }
            let nameBytes = data.subdata(in: (data.startIndex + nameStart)..<(data.startIndex + extraStart))
            let name = String(data: nameBytes, encoding: .utf8) ?? String(decoding: nameBytes, as: UTF8.self)
            if compressed == 0xFFFF_FFFF || uncompressed == 0xFFFF_FFFF || offset == 0xFFFF_FFFF {
                // The ZIP64 extra field lists only the values whose classic fields are saturated, in this order.
                var extra = extraStart
                let extraEnd = extraStart + extraLength
                var found = false
                while extra <= extraEnd - 4 {
                    let id = readUInt16(data, extra)
                    let size = Int(readUInt16(data, extra + 2))
                    let body = extra + 4
                    guard size <= extraEnd - body else { throw ZipError.truncated }
                    if id == 0x0001 {
                        var field = body
                        func take() throws -> UInt64 {
                            guard field <= body + size - 8 else { throw ZipError.truncated }
                            defer { field += 8 }
                            return readUInt64(data, field)
                        }
                        if uncompressed == 0xFFFF_FFFF { uncompressed = try take() }
                        if compressed == 0xFFFF_FFFF { compressed = try take() }
                        if offset == 0xFFFF_FFFF { offset = try take() }
                        found = true
                        break
                    }
                    extra = body + size
                }
                guard found else { throw ZipError.truncated }
            }
            guard let compressedSize = Int(exactly: compressed), let uncompressedSize = Int(exactly: uncompressed),
                  let localOffset = Int(exactly: offset) else { throw ZipError.truncated }
            entries.append(Entry(name: name, method: method, flags: flags, crc32: crc, compressedSize: compressedSize,
                                 uncompressedSize: uncompressedSize, localHeaderOffset: localOffset))
            cursor = next
        }
        return entries
    }
}

/// Little-endian reads by byte, so unaligned offsets are safe. Callers bounds-check first.
private func readUInt16(_ data: Data, _ offset: Int) -> UInt16 {
    guard offset >= 0, offset <= data.count - 2 else { return 0 }
    let base = data.startIndex + offset
    return UInt16(data[base]) | UInt16(data[base + 1]) << 8
}

private func readUInt32(_ data: Data, _ offset: Int) -> UInt32 {
    guard offset >= 0, offset <= data.count - 4 else { return 0 }
    let base = data.startIndex + offset
    return (0..<4).reduce(UInt32(0)) { $0 | UInt32(data[base + $1]) << ($1 * 8) }
}

private func readUInt64(_ data: Data, _ offset: Int) -> UInt64 {
    guard offset >= 0, offset <= data.count - 8 else { return 0 }
    let base = data.startIndex + offset
    return (0..<8).reduce(UInt64(0)) { $0 | UInt64(data[base + $1]) << ($1 * 8) }
}

private let crc32Table: [UInt32] = (0..<256).map { index -> UInt32 in
    var value = UInt32(index)
    for _ in 0..<8 { value = value & 1 == 1 ? 0xEDB8_8320 ^ (value >> 1) : value >> 1 }
    return value
}

/// CRC-32 (IEEE 802.3), as stored in ZIP headers.
func zipCRC32(_ data: Data) -> UInt32 {
    var crc: UInt32 = 0xFFFF_FFFF
    crc32Table.withUnsafeBufferPointer { table in
        data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            for byte in bytes { crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8) }
        }
    }
    return crc ^ 0xFFFF_FFFF
}
