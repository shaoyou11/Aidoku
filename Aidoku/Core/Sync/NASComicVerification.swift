import CryptoKit
import Foundation
import ZIPFoundation

/// Verification is independent of the phone download cache and never trusts a matching filename alone.
enum NASComicVerification {
    static func digest(_ file: URL) throws -> SHA256.Digest {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hash = SHA256()
        while let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty { hash.update(data: data) }
        return hash.finalize()
    }

    static func matches(_ first: URL, _ second: URL) throws -> Bool {
        try digest(first) == digest(second)
    }

    static func archiveContents(_ file: URL) throws -> [String: String] {
        let archive = try Archive(url: file, accessMode: .read)
        var result: [String: String] = [:]
        for entry in archive where entry.type != .directory {
            guard entry.type == .file, result[entry.path] == nil else { throw NASComicError.invalidArchive }
            var hash = SHA256()
            let crc = try archive.extract(entry) { hash.update(data: $0) }
            guard crc == entry.checksum else { throw NASComicError.invalidArchive }
            result[entry.path] = hash.finalize().map { String(format: "%02x", $0) }.joined()
        }
        guard !result.isEmpty else { throw NASComicError.invalidArchive }
        return result
    }

    /// Re-exporting a folder may change ZIP timestamps without changing any chapter contents.
    static func sameChapter(_ first: URL, _ second: URL) throws -> Bool {
        if try matches(first, second) { return true }
        return try archiveContents(first) == archiveContents(second)
    }

    /// Build a complete manifest before removing anything. Only files belonging to this verified chapter qualify.
    static func localFiles(directory: URL, archive verified: URL) throws -> [URL] {
        let file = directory.appendingPathExtension("cbz")
        if FileManager.default.fileExists(atPath: file.path) {
            guard !FileManager.default.fileExists(atPath: directory.path),
                  try file.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true,
                  try sameChapter(file, verified) else { throw NASComicError.localChanged }
            return [file]
        }
        guard try directory.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else { throw NASComicError.localChanged }
        let directory = directory.resolvingSymlinksInPath().standardizedFileURL
        let archive = try Archive(url: verified, accessMode: .read)
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey]
        guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: Array(keys)) else {
            throw NASComicError.localChanged
        }
        var local: [String: URL] = [:]
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: keys)
            guard values.isSymbolicLink != true else { throw NASComicError.localChanged }
            if values.isRegularFile == true {
                let path = url.resolvingSymlinksInPath().standardizedFileURL.path
                guard path.hasPrefix(directory.path + "/") else { throw NASComicError.localChanged }
                local[String(path.dropFirst(directory.path.count + 1))] = url
            }
        }
        var result: [URL] = []
        for entry in archive where entry.type != .directory {
            guard entry.type == .file, let file = local.removeValue(forKey: entry.path) else { throw NASComicError.localChanged }
            var hash = SHA256()
            let crc = try archive.extract(entry) { hash.update(data: $0) }
            guard crc == entry.checksum, hash.finalize() == (try digest(file)) else { throw NASComicError.localChanged }
            result.append(file)
        }
        guard local.isEmpty, !result.isEmpty else { throw NASComicError.localChanged }
        return result
    }
}
