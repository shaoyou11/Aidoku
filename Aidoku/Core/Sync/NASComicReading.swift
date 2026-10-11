import AidokuRunner
import Foundation
import ZIPFoundation

struct NASComicLink: Codable {
    let source: String
    let manga: String
    let chapter: String
    let path: String
    let size: Int64
    var explicit: Bool? = nil
}

extension NASComicManager {
    static func sourcePreferenceKey(_ manga: MangaIdentifier) -> String {
        "NASComics.reading." + NASComicPaths.hash(manga.sourceKey + "\n" + manga.mangaKey)
    }
    static func linkPath(source: String, manga: String, chapter: String) -> String {
        ".aidokut-links/" + NASComicPaths.hash(source + "\n" + manga + "\n" + chapter) + ".json"
    }
    func linkedPages(manga: AidokuRunner.Manga, chapter: AidokuRunner.Chapter) async throws -> [AidokuRunner.Page]? {
        guard manga.sourceKey != NASSourceRunner.sourceKey, manga.sourceKey != LocalSourceRunner.sourceKey,
              UserDefaults.standard.string(forKey: Self.sourcePreferenceKey(manga.identifier)) != "original",
              let config = try? configuration() else { return nil }
        let path = Self.linkPath(source: manga.sourceKey, manga: manga.key, chapter: chapter.key)
        let cacheKey = "NASComics.link." + NASComicPaths.hash(config.fingerprint + path)
        // No known uploaded chapter means no NAS request at all, including sibling chapters.
        guard let data = UserDefaults.standard.data(forKey: cacheKey),
              let link = try? JSONDecoder().decode(NASComicLink.self, from: data),
              link.source == manga.sourceKey, link.manga == manga.key, link.chapter == chapter.key else { return nil }
        _ = try NASComicPaths.url(link.path, root: config.root)
        let entries = try await entries((link.path as NSString).deletingLastPathComponent, refresh: false)
        guard let entry = entries.first(where: { $0.path == link.path && !$0.isDirectory }) else { return nil }
        return try await onlinePages(entry)
    }
    func isComicVisible(path: String, isDirectory: Bool) -> Bool {
        guard let config = try? configuration() else { return true }
        guard PrivacyDisplayStore.shared.policy.hidesExplicit else { return true }
        guard PrivacyDisplayStore.shared.policy.knownRatingsLoaded else { return false }
        return !isComicExplicit(path: path, isDirectory: isDirectory, config: config)
    }
    func isComicExplicit(path: String, isDirectory: Bool, config: Configuration) -> Bool {
        let current = PrivacyDisplayStore.shared.policy
        let policy = PrivacyDisplayPolicy(enabled: true, marked: current.marked, knownExplicit: current.knownExplicit, explicitSources: current.explicitSources)
        let folder = isDirectory ? path : (path as NSString).deletingLastPathComponent
        let nasId = MangaIdentifier(sourceKey: NASSourceRunner.sourceKey, mangaKey: NASComicPaths.key(folder, fingerprint: config.fingerprint))
        guard policy.allows(nasId) else { return true }
        for (key, value) in UserDefaults.standard.dictionaryRepresentation() where key.hasPrefix("NASComics.link.") {
            guard let data = value as? Data, let link = try? JSONDecoder().decode(NASComicLink.self, from: data),
                  key == "NASComics.link." + NASComicPaths.hash(config.fingerprint + Self.linkPath(source: link.source, manga: link.manga, chapter: link.chapter)),
                  (link.path as NSString).deletingLastPathComponent == folder else { continue }
            if !policy.allows(.init(sourceKey: link.source, mangaKey: link.manga), rating: link.explicit == true ? 2 : -1) { return true }
        }
        return false
    }
    /// Explicit refresh imports chapter associations on a second device without slowing normal reading.
    func refreshUploadedLinks() async throws -> Int {
        let config = try configuration()
        let client = try NASComicClient(connection: config.connection, root: config.root)
        defer { client.close() }
        let entries = try await client.list(".aidokut-links", extensions: ["json"])
        var count = 0
        for entry in entries where !entry.isDirectory {
            try Task.checkCancellation()
            guard let data = try await client.readLink(entry.path),
                  let link = try? JSONDecoder().decode(NASComicLink.self, from: data),
                  Self.linkPath(source: link.source, manga: link.manga, chapter: link.chapter) == entry.path,
                  (try? NASComicPaths.url(link.path, root: config.root)) != nil else { continue }
            UserDefaults.standard.set(data, forKey: "NASComics.link." + NASComicPaths.hash(config.fingerprint + entry.path))
            count += 1
        }
        return count
    }
    func onlinePages(_ entry: NASComicEntry) async throws -> [AidokuRunner.Page] {
        if isCached(entry) {
            let archive = try await cachedArchive(entry)
            return LocalFileManager.shared.readPages(from: archive)
        }
        let config = try configuration()
        let client = try NASComicClient(connection: config.connection, root: config.root)
        defer { client.close() }
        guard entry.size > 22 else { throw NASComicError.requiresWholeArchive }
        let count = min(entry.size, 65557)
        let tail = try await client.range(entry, start: entry.size - count, count: count)
        let directory = try NASZIPIndex.directory(tail: tail, total: entry.size)
        let central = try await client.range(entry, start: directory.offset, count: directory.count)
        let pages = try NASZIPIndex.entries(central)
        return try pages.map { page in
            let context = NASOnlinePage(archive: entry, page: page, fingerprint: config.fingerprint)
            let encoded = try JSONEncoder().encode(context).base64EncodedString()
            let id = NASComicPaths.hash(config.fingerprint + entry.path + (entry.etag ?? "") + String(entry.size) + page.name)
            return .init(content: .url(url: URL(string: "nascomic://page/" + id)!, context: ["nasPage": encoded]))
        }
    }
    func onlineImageData(context: PageContext?) async throws -> Data {
        guard let encoded = context?["nasPage"], let data = Data(base64Encoded: encoded), data.count <= 128 * 1024,
              let page = try? JSONDecoder().decode(NASOnlinePage.self, from: data) else { throw NASComicError.invalidArchive }
        let config = try configuration()
        guard config.fingerprint == page.fingerprint else { throw NASComicError.wrongConnection }
        let client = try NASComicClient(connection: config.connection, root: config.root)
        defer { client.close() }
        let header = try await client.range(page.archive, start: page.page.offset, count: 30)
        guard NASZIPIndex.u32(header, 0) == 0x04034b50 else { throw NASComicError.invalidArchive }
        let length = Int64(30 + Int(NASZIPIndex.u16(header, 26)) + Int(NASZIPIndex.u16(header, 28))) + page.page.compressedSize
        let local = try await client.range(page.archive, start: page.page.offset, count: length)
        return try Self.decodeOnlinePage(local, entry: page.page)
    }
    nonisolated static func decodeOnlinePage(_ local: Data, entry: NASZIPEntry) throws -> Data {
        let zip = try NASZIPIndex.singleArchive(local: local, entry: entry)
        let archive = try Archive(data: zip, accessMode: .read)
        guard let item = archive[entry.name] else { throw NASComicError.invalidArchive }
        var output = Data()
        let crc = try archive.extract(item) { block in
            guard output.count + block.count <= 64 * 1024 * 1024 else { throw NASComicError.invalidArchive }
            output.append(block)
        }
        guard crc == entry.crc, output.count == entry.size else { throw NASComicError.invalidArchive }
        return output
    }
}

private struct NASOnlinePage: Codable {
    let archive: NASComicEntry
    let page: NASZIPEntry
    let fingerprint: String
}
