import AidokuRunner
import Foundation
import ImageIO
import UIKit

/// Small local previews, independent of the phone's downloaded chapter files.
struct NASComicMetadata: Codable {
    let xml: String?
    let pageCount: Int
    let coverFile: String?
    var info: ComicInfo? { xml.flatMap { ComicInfo.load(xmlString: $0) } }
}

extension NASComicManager {
    private func previewDirectory() throws -> URL {
        let base = try FileManager.default.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let directory = base.appendingPathComponent("NASComicPreviews", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    func metadata(_ entry: NASComicEntry, cover: Bool) async throws -> NASComicMetadata {
        let config = try configuration()
        let directory = try previewDirectory()
        let id = NASComicPaths.hash(config.fingerprint + entry.path + (entry.etag ?? "") + String(entry.size))
        let saved = directory.appendingPathComponent(id + ".json")
        if let bytes = try? Data(contentsOf: saved), let cached = try? JSONDecoder().decode(NASComicMetadata.self, from: bytes),
           !cover || cached.coverFile.map({ FileManager.default.fileExists(atPath: directory.appendingPathComponent($0).path) }) == true {
            return cached
        }
        let client = try NASComicClient(connection: config.connection, root: config.root)
        defer { client.close() }
        guard entry.size > 22 else { throw NASComicError.invalidArchive }
        let count = min(entry.size, 65557)
        let tail = try await client.range(entry, start: entry.size - count, count: count)
        let index = try NASZIPIndex.directory(tail: tail, total: entry.size)
        let central = try await client.range(entry, start: index.offset, count: index.count)
        let records = try NASZIPIndex.entries(central, includeMetadata: true)
        let pages = records.filter { ($0.name as NSString).lastPathComponent.lowercased() != "comicinfo.xml" }
        guard !pages.isEmpty else { throw NASComicError.invalidArchive }
        var xml: String?
        if let record = records.first(where: { ($0.name as NSString).lastPathComponent.lowercased() == "comicinfo.xml" }) {
            xml = String(data: try await archiveData(record, archive: entry, client: client), encoding: .utf8)
        }
        var coverFile: String?
        if cover, let first = pages.first {
            let bytes = try await archiveData(first, archive: entry, client: client)
            let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                          kCGImageSourceThumbnailMaxPixelSize: 480,
                                          kCGImageSourceCreateThumbnailWithTransform: true]
            if let source = CGImageSourceCreateWithData(bytes as CFData, nil),
               let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
               let jpeg = UIImage(cgImage: image).jpegData(compressionQuality: 0.82) {
                let name = id + ".jpg"
                try jpeg.write(to: directory.appendingPathComponent(name), options: [.atomic, .completeFileProtection])
                coverFile = name
            }
        }
        try Task.checkCancellation()
        let result = NASComicMetadata(xml: xml, pageCount: pages.count, coverFile: coverFile)
        try JSONEncoder().encode(result).write(to: saved, options: [.atomic, .completeFileProtection])
        return result
    }

    func detailedManga(folder: String, entries: [NASComicEntry], allChapters: Bool = true) async throws -> AidokuRunner.Manga {
        var result = try manga(folder: folder, entries: entries)
        let knownExplicit = result.contentRating == .nsfw
        let files = entries.filter { !$0.isDirectory }
        var chapters = result.chapters ?? []
        for (index, entry) in files.enumerated() {
            try Task.checkCancellation()
            guard allChapters || index == 0 else { break }
            // A missing preview must not block browsing or opening otherwise readable chapters.
            guard let preview = try? await metadata(entry, cover: index == 0) else { continue }
            let key = NASComicPaths.key(entry.path, fingerprint: try configuration().fingerprint)
            if let info = preview.info {
                if index == 0 { result = info.copy(into: result) }
                if let position = chapters.firstIndex(where: { $0.key == key }) {
                    chapters[position] = info.copy(into: chapters[position])
                }
                // Preserve an explicit rating discovered in imported ComicInfo files.
                if info.ageRating == .r18Plus { result.contentRating = .nsfw }
            }
            if index == 0, let cover = preview.coverFile {
                result.cover = try previewDirectory().appendingPathComponent(cover).absoluteString
            }
        }
        if knownExplicit { result.contentRating = .nsfw }
        result.chapters = chapters
        if result.description?.isEmpty != false {
            result.description = "NAS 已保存 \(files.count) 个章节，可按页在线阅读。未上传的章节仍从原图源读取。"
        }
        return result
    }
}
