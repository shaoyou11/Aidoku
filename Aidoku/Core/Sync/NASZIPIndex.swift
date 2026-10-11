import Foundation

struct NASZIPEntry: Codable, Sendable {
    let name: String
    let offset: Int64
    let compressedSize: Int64
    let size: Int64
    let crc: UInt32
    let centralRecord: Data
}

/// Reads only ZIP metadata; ZIP64, encrypted and unsupported archives require explicit whole-chapter caching.
enum NASZIPIndex {
    static func u16(_ data: Data, _ offset: Int) -> UInt16 {
        UInt16(data[offset]) | UInt16(data[offset + 1]) << 8
    }
    static func u32(_ data: Data, _ offset: Int) -> UInt32 {
        UInt32(u16(data, offset)) | UInt32(u16(data, offset + 2)) << 16
    }
    static func directory(tail: Data, total: Int64) throws -> (offset: Int64, count: Int64) {
        guard tail.count >= 22 else { throw NASComicError.invalidArchive }
        for index in stride(from: tail.count - 22, through: 0, by: -1) where u32(tail, index) == 0x06054b50 {
            guard index + 22 + Int(u16(tail, index + 20)) == tail.count else { continue }
            guard u16(tail, index + 4) == 0, u16(tail, index + 6) == 0,
                  u16(tail, index + 8) == u16(tail, index + 10), u16(tail, index + 10) != 65535 else { throw NASComicError.requiresWholeArchive }
            let size = Int64(u32(tail, index + 12)), offset = Int64(u32(tail, index + 16))
            guard size > 0, size <= 8 * 1024 * 1024, offset + size <= total - Int64(tail.count - index) else { throw NASComicError.invalidArchive }
            return (offset, size)
        }
        throw NASComicError.invalidArchive
    }
    static func entries(_ data: Data) throws -> [NASZIPEntry] {
        var offset = 0
        var result: [NASZIPEntry] = []
        let extensions: Set<String> = ["jpg", "jpeg", "png", "webp", "gif", "heic", "avif"]
        while offset < data.count {
            guard offset + 46 <= data.count, u32(data, offset) == 0x02014b50 else { throw NASComicError.invalidArchive }
            let flags = u16(data, offset + 8), method = u16(data, offset + 10)
            let nameSize = Int(u16(data, offset + 28))
            let length = 46 + nameSize + Int(u16(data, offset + 30)) + Int(u16(data, offset + 32))
            guard offset + length <= data.count, flags & 1 == 0, u16(data, offset + 34) == 0,
                  method == 0 || method == 8 else { throw NASComicError.requiresWholeArchive }
            let nameData = data.subdata(in: offset + 46 ..< offset + 46 + nameSize)
            guard let name = String(data: nameData, encoding: .utf8) else { throw NASComicError.requiresWholeArchive }
            guard !name.hasPrefix("/"), !name.contains("\\"), !name.split(separator: "/").contains("..") else { throw NASComicError.invalidArchive }
            let compressed = Int64(u32(data, offset + 20)), size = Int64(u32(data, offset + 24)), local = Int64(u32(data, offset + 42))
            guard compressed < UInt32.max, size < UInt32.max, local < UInt32.max else { throw NASComicError.requiresWholeArchive }
            if extensions.contains((name as NSString).pathExtension.lowercased()), !(name as NSString).lastPathComponent.hasPrefix(".") {
                guard compressed > 0, compressed <= 64 * 1024 * 1024, size > 0, size <= 64 * 1024 * 1024,
                      result.count < 20000 else { throw NASComicError.invalidArchive }
                result.append(.init(name: name, offset: local, compressedSize: compressed, size: size,
                                    crc: u32(data, offset + 16), centralRecord: data.subdata(in: offset ..< offset + length)))
            }
            offset += length
        }
        guard !result.isEmpty else { throw NASComicError.requiresWholeArchive }
        return result.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    static func singleArchive(local: Data, entry: NASZIPEntry) throws -> Data {
        guard local.count >= 30, u32(local, 0) == 0x04034b50,
              Int64(local.count) == 30 + Int64(u16(local, 26)) + Int64(u16(local, 28)) + entry.compressedSize else { throw NASComicError.invalidArchive }
        var central = entry.centralRecord
        central.replaceSubrange(42..<46, with: [0, 0, 0, 0])
        var zip = local
        zip.append(central)
        func append16(_ value: UInt16) { zip.append(UInt8(value & 255)); zip.append(UInt8(value >> 8)) }
        func append32(_ value: UInt32) { append16(UInt16(value & 65535)); append16(UInt16(value >> 16)) }
        append32(0x06054b50); append16(0); append16(0); append16(1); append16(1)
        append32(UInt32(central.count)); append32(UInt32(local.count)); append16(0)
        return zip
    }
}
