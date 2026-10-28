import Foundation
import zlib

/// A signed feed has only a JSON file and, on macOS, its AppleDouble
/// signature metadata. Decode that small envelope before giving a native
/// extractor anything: ZIP size fields are untrusted and can lie.
enum UpdateFeedArchive {
    static let compressedLimit = 1 << 20
    static let fileLimit = 1 << 20
    static let expandedLimit = 2 << 20

    enum Refused: Error { case malformed, tooLarge }

    private struct Entry {
        let name: String
        let bytes: Data
    }

    /// Rebuild a stored ZIP with validated names, sizes, checksums and data.
    /// ditto can then restore the bounded AppleDouble signature attributes
    /// without interpreting attacker-controlled compressed streams or paths.
    static func normalized(_ packed: Data) throws -> Data {
        guard packed.count <= compressedLimit else { throw Refused.tooLarge }
        guard packed.count >= 22 else { throw Refused.malformed }
        let bytes = [UInt8](packed)
        func word(_ at: Int) throws -> Int {
            guard at >= 0, at + 2 <= bytes.count else { throw Refused.malformed }
            return Int(bytes[at]) | Int(bytes[at + 1]) << 8
        }
        func long(_ at: Int) throws -> Int {
            try word(at) | word(at + 2) << 16
        }
        var end: Int?
        for at in stride(from: bytes.count - 22, through: max(0, bytes.count - 65_557), by: -1) {
            if try long(at) == 0x06054b50, at + 22 + (try word(at + 20)) == bytes.count { end = at; break }
        }
        guard let end, try word(end + 4) == 0, (try word(end + 6)) == 0,
              (try word(end + 8)) == (try word(end + 10)) else { throw Refused.malformed }
        let count = try word(end + 10)
        let directorySize = try long(end + 12), directory = try long(end + 16)
        guard count > 0, count <= 3, directory + directorySize == end else { throw Refused.malformed }
        var position = directory
        var seen: Set<String> = []
        var ranges: [Range<Int>] = []
        var entries: [Entry] = []
        var expanded = 0
        for _ in 0..<count {
            guard try long(position) == 0x02014b50 else { throw Refused.malformed }
            let flags = try word(position + 8), method = try word(position + 10)
            let checksum = try long(position + 16)
            let size = try long(position + 20), outputSize = try long(position + 24)
            let nameSize = try word(position + 28), extraSize = try word(position + 30), commentSize = try word(position + 32)
            let local = try long(position + 42)
            let next = position + 46 + nameSize + extraSize + commentSize
            guard next <= end, try word(position + 34) == 0, flags & ~0x080e == 0,
                  method == 0 || method == 8,
                  let name = String(bytes: bytes[(position + 46)..<(position + 46 + nameSize)], encoding: .utf8),
                  ["appcast.json", "__MACOSX/._appcast.json", "__MACOSX/"].contains(name),
                  seen.insert(name).inserted else { throw Refused.malformed }
            let kind = (try long(position + 38) >> 16) & 0xf000
            guard kind == 0 || kind == (name.hasSuffix("/") ? 0x4000 : 0x8000) else { throw Refused.malformed }
            guard outputSize <= fileLimit, expanded + outputSize <= expandedLimit else { throw Refused.tooLarge }
            expanded += outputSize
            guard try long(local) == 0x04034b50, (try word(local + 6)) == flags, (try word(local + 8)) == method else { throw Refused.malformed }
            let localNameSize = try word(local + 26), localExtra = try word(local + 28)
            let dataStart = local + 30 + localNameSize + localExtra, dataEnd = dataStart + size
            guard local >= 0, local + 30 + localNameSize <= directory, dataEnd <= directory,
                  Array(bytes[(local + 30)..<(local + 30 + localNameSize)]) == Array(name.utf8) else { throw Refused.malformed }
            let range = local..<dataEnd
            guard !ranges.contains(where: { $0.overlaps(range) }) else { throw Refused.malformed }
            ranges.append(range)
            if name.hasSuffix("/") {
                guard size == 0, outputSize == 0 else { throw Refused.malformed }
            } else {
                let compressed = Data(bytes[dataStart..<dataEnd])
                let decoded = try decode(compressed, method: method, expected: outputSize)
                guard crc(decoded) == UInt32(checksum) else { throw Refused.malformed }
                entries.append(Entry(name: name, bytes: decoded))
            }
            position = next
        }
        guard position == end, seen.contains("appcast.json") else { throw Refused.malformed }
        return stored(entries)
    }

    private static func decode(_ compressed: Data, method: Int, expected: Int) throws -> Data {
        if method == 0 {
            guard compressed.count == expected else { throw Refused.malformed }
            return compressed
        }
        // One extra byte detects a lying uncompressed size while preserving
        // a hard allocation bound, including zero-length entries.
        var output = [UInt8](repeating: 0, count: expected + 1)
        var stream = z_stream()
        guard inflateInit2_(&stream, -MAX_WBITS, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else { throw Refused.malformed }
        defer { inflateEnd(&stream) }
        let status = compressed.withUnsafeBytes { input in
            output.withUnsafeMutableBytes { destination in
                stream.next_in = UnsafeMutablePointer(mutating: input.bindMemory(to: Bytef.self).baseAddress)
                stream.avail_in = uInt(compressed.count)
                stream.next_out = destination.bindMemory(to: Bytef.self).baseAddress
                stream.avail_out = uInt(destination.count)
                return inflate(&stream, Z_FINISH)
            }
        }
        guard status == Z_STREAM_END, stream.total_in == compressed.count,
              stream.total_out == expected else { throw Refused.malformed }
        return Data(output.prefix(expected))
    }

    private static func crc(_ data: Data) -> UInt32 {
        data.withUnsafeBytes { UInt32(crc32(0, $0.bindMemory(to: Bytef.self).baseAddress, uInt(data.count))) }
    }

    private static func stored(_ entries: [Entry]) -> Data {
        var zip = Data(), directory = Data()
        for entry in entries {
            let name = Data(entry.name.utf8), offset = zip.count, checksum = crc(entry.bytes)
            zip.zip32(0x04034b50); zip.zip16(20); zip.zip16(0); zip.zip16(0); zip.zip16(0); zip.zip16(0)
            zip.zip32(checksum); zip.zip32(UInt32(entry.bytes.count)); zip.zip32(UInt32(entry.bytes.count))
            zip.zip16(UInt16(name.count)); zip.zip16(0); zip.append(name); zip.append(entry.bytes)
            directory.zip32(0x02014b50); directory.zip16(0x0314); directory.zip16(20)
            directory.zip16(0); directory.zip16(0); directory.zip16(0); directory.zip16(0)
            directory.zip32(checksum); directory.zip32(UInt32(entry.bytes.count)); directory.zip32(UInt32(entry.bytes.count))
            directory.zip16(UInt16(name.count)); directory.zip16(0); directory.zip16(0); directory.zip16(0); directory.zip16(0)
            directory.zip32(0x81800000); directory.zip32(UInt32(offset)); directory.append(name)
        }
        let start = zip.count
        zip.append(directory)
        zip.zip32(0x06054b50); zip.zip16(0); zip.zip16(0)
        zip.zip16(UInt16(entries.count)); zip.zip16(UInt16(entries.count))
        zip.zip32(UInt32(directory.count)); zip.zip32(UInt32(start)); zip.zip16(0)
        return zip
    }
}

private extension Data {
    mutating func zip16(_ value: UInt16) {
        var little = value.littleEndian
        Swift.withUnsafeBytes(of: &little) { append(contentsOf: $0) }
    }
    mutating func zip32(_ value: UInt32) {
        var little = value.littleEndian
        Swift.withUnsafeBytes(of: &little) { append(contentsOf: $0) }
    }
}
