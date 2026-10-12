import AidokuRunner
import CryptoKit
import SwiftUI
import ZIPFoundation

@MainActor
final class NASComicManager: ObservableObject {
    static let shared = NASComicManager()
    @Published private(set) var busy = false
    @Published private(set) var status = "优先按页在线阅读，整章离线缓存可选"
    @Published private(set) var progress: Double?
    @Published private(set) var cacheBytes: Int64 = 0
    @Published private(set) var lastUpload: NASComicUploadSummary?
    private var transfer: Task<Void, Never>?
    private var activeClient: NASComicClient?
    private let cacheLimit: Int64 = 2 * 1024 * 1024 * 1024

    private init() {
        if let data = UserDefaults.standard.data(forKey: "NASComics.lastUpload"),
           var summary = try? JSONDecoder().decode(NASComicUploadSummary.self, from: data) {
            if summary.state == .uploading {
                summary.state = .cancelled
                summary.error = "上次上传未完成；已完成章节保留，可重新上传剩余章节。"
            }
            lastUpload = summary
        }
    }

    private func updateUpload(_ update: (inout NASComicUploadSummary) -> Void) {
        guard var summary = lastUpload else { return }
        update(&summary)
        summary.updatedAt = Date()
        lastUpload = summary
        if let data = try? JSONEncoder().encode(summary) {
            UserDefaults.standard.set(data, forKey: "NASComics.lastUpload")
        }
    }

    struct Configuration {
        let connection: NASConnection
        let root: URL
        let fingerprint: String
    }
    func configuration() throws -> Configuration {
        let connection = try NASSyncManager.shared.loadConnection()
        let base = try connection.folderURL()
        let setting = "NASComics.root." + NASComicPaths.fingerprint(connection, root: base)
        let root = UserDefaults.standard.string(forKey: setting).flatMap(URL.init(string:))
            ?? base.appendingPathComponent("AidokuT-Comics", isDirectory: true)
        guard NASConnection.sameOrigin(base, root) else { throw NASSyncError.invalidAddress }
        return .init(connection: connection, root: root, fingerprint: NASComicPaths.fingerprint(connection, root: root))
    }
    func selectFolder(_ url: URL) throws {
        guard !busy else { throw NASComicError.busy }
        let config = try configuration()
        guard NASConnection.sameOrigin(config.root, url) else { throw NASSyncError.invalidAddress }
        let base = try config.connection.folderURL()
        UserDefaults.standard.set(url.absoluteString, forKey: "NASComics.root." + NASComicPaths.fingerprint(config.connection, root: base))
        status = "漫画文件夹已保存"
    }
    private func client(_ config: Configuration) throws -> NASComicClient {
        try NASComicClient(connection: config.connection, root: config.root) { [weak self] done, total in
            Task { @MainActor in self?.progress = total > 0 ? min(1, Double(done) / Double(total)) : nil }
        }
    }
    func cancel() {
        transfer?.cancel()
        activeClient?.close()
        status = "已取消；已完成的章节保留，可重新上传剩余章节"
    }
    private func directory(_ kind: FileManager.SearchPathDirectory, name: String) throws -> URL {
        let base = try FileManager.default.url(for: kind, in: .userDomainMask, appropriateFor: nil, create: true)
        let folder = base.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }
    private func listingURL(_ path: String, config: Configuration) throws -> URL {
        try directory(.applicationSupportDirectory, name: "NASComicLists")
            .appendingPathComponent(NASComicPaths.hash(config.fingerprint + ":" + path) + ".json")
    }
    func entries(_ path: String, refresh: Bool = true) async throws -> [NASComicEntry] {
        let config = try configuration()
        let saved = try listingURL(path, config: config)
        if !refresh, let data = try? Data(contentsOf: saved), let entries = try? JSONDecoder().decode([NASComicEntry].self, from: data) { return entries }
        let client = try client(config)
        defer { client.close() }
        do {
            let entries = try await client.list(path)
            try Task.checkCancellation()
            try JSONEncoder().encode(entries).write(to: saved, options: [.atomic, .completeFileProtection])
            if !busy { status = "目录已更新 · " + client.routeLabel }
            return entries
        } catch {
            guard !Task.isCancelled, (error as? URLError)?.code != .cancelled else { throw CancellationError() }
            if let data = try? Data(contentsOf: saved), let entries = try? JSONDecoder().decode([NASComicEntry].self, from: data) {
                if !busy { status = "网络读取失败，显示上次目录；已缓存章节仍可阅读。" }
                return entries
            }
            throw error
        }
    }
    func createLibrary() async {
        guard !busy else { return }
        busy = true
        status = "正在准备漫画目录…"
        defer { busy = false }
        do {
            let config = try configuration()
            let client = try client(config)
            defer { client.close() }
            try await client.ensureFolder("")
            status = "漫画目录已准备好 · " + client.routeLabel
        } catch { status = NASConnection.message(for: error) }
    }
    func enableSource() async {
        if SourceManager.shared.store.source(for: NASSourceRunner.sourceKey) == nil {
            await SourceManager.shared.createCustomSource(.nas)
        }
    }
    func upload(manga: DownloadedMangaInfo, chapters: [DownloadedChapterInfo]) {
        guard !busy else { return }
        busy = true; progress = nil; status = "正在准备上传…"
        lastUpload = nil
        transfer = Task {
            defer { busy = false; progress = nil; activeClient = nil; transfer = nil }
            do {
                let config = try configuration()
                let completed = chapters.filter { !$0.failed }
                let folder = NASComicPaths.filename(manga.displayTitle, identity: manga.id)
                lastUpload = .init(sourceID: manga.sourceId, mangaID: manga.mangaId, title: manga.displayTitle,
                                   folder: folder, fingerprint: config.fingerprint, total: completed.count)
                updateUpload { _ in }
                let client = try client(config)
                activeClient = client
                defer { client.close() }
                try await client.ensureFolder("")
                try await client.ensureFolder(".aidokut-links")
                try await client.ensureFolder(folder)
                var uploaded = 0
                var skipped = 0
                var failed = 0
                for (index, chapter) in completed.enumerated() {
                    try Task.checkCancellation()
                    status = "上传 \(index + 1)/\(completed.count) · \(chapter.displayTitle)"
                    progress = nil
                    let identifier = ChapterIdentifier(sourceKey: manga.sourceId, mangaKey: manga.mangaId, chapterKey: chapter.chapterId)
                    // A unique export name avoids clashing with the share sheet's temporary archive.
                    let file = try await DownloadManager.shared.makeNASArchive(for: identifier)
                    defer { try? FileManager.default.removeItem(at: file) }
                    let name = NASComicPaths.filename(chapter.displayTitle, identity: chapter.chapterId) + ".cbz"
                    do {
                        try await client.upload(file, path: folder + "/" + name)
                        uploaded += 1
                        updateUpload { $0.uploaded = uploaded }
                    } catch NASComicError.exists {
                        skipped += 1
                        updateUpload { $0.skipped = skipped }
                    }
                    catch {
                        if Task.isCancelled || (error as? URLError)?.code == .cancelled { throw CancellationError() }
                        failed += 1
                        // Stop on a connection/permission error; completed files remain valid and repeat uploads skip them.
                        status = "已上传 \(uploaded) 章，跳过 \(skipped) 章；当前章节失败：" + NASConnection.message(for: error)
                        updateUpload { $0.state = .failed; $0.error = NASConnection.message(for: error) }
                        return
                    }
                    let size = Int64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
                    let link = NASComicLink(source: manga.sourceId, manga: manga.mangaId, chapter: chapter.chapterId, path: folder + "/" + name, size: size, explicit: !PrivacyDisplayPolicy(enabled: true, marked: PrivacyDisplayStore.shared.policy.marked, knownExplicit: PrivacyDisplayStore.shared.policy.knownExplicit, explicitSources: PrivacyDisplayStore.shared.policy.explicitSources).allows(.init(sourceKey: manga.sourceId, mangaKey: manga.mangaId)))
                    let linkPath = Self.linkPath(source: manga.sourceId, manga: manga.mangaId, chapter: chapter.chapterId)
                    let linkData = try JSONEncoder().encode(link)
                    do {
                        try await client.writeLink(linkData, path: linkPath)
                    } catch {
                        if Task.isCancelled || (error as? URLError)?.code == .cancelled { throw CancellationError() }
                        status = "章节文件已在 NAS，但阅读关联未保存；重试上传可补齐关联。"
                        updateUpload { $0.state = .failed; $0.error = status + " " + NASConnection.message(for: error) }
                        return
                    }
                    UserDefaults.standard.set(linkData, forKey: "NASComics.link." + NASComicPaths.hash(config.fingerprint + linkPath))
                    updateUpload { $0.linked += 1 }
                }
                status = "上传完成：\(uploaded) 章，同名跳过 \(skipped) 章，失败 \(failed) 章 · " + client.routeLabel
                updateUpload { $0.state = .completed }
                _ = try? await entries(folder)
                _ = try? await entries("")
            } catch is CancellationError {
                status = "上传已取消，已完成的章节保留；重试会跳过同名文件。"
                updateUpload { $0.state = .cancelled; $0.error = status }
            } catch {
                status = NASConnection.message(for: error)
                updateUpload { $0.state = .failed; $0.error = status }
            }
        }
    }
    private func cacheURL(_ entry: NASComicEntry, config: Configuration) throws -> URL {
        // Include ETag/size so a changed server file cannot silently reuse old cached pages.
        let identity = config.fingerprint + ":" + entry.path + ":" + (entry.etag ?? "") + ":" + String(entry.size)
        return try directory(.cachesDirectory, name: "NASComicChapters").appendingPathComponent(NASComicPaths.hash(identity) + ".cbz")
    }
    func isCached(_ entry: NASComicEntry) -> Bool {
        guard let config = try? configuration(), let url = try? cacheURL(entry, config: config) else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }
    func refreshCacheSize() {
        guard let folder = try? directory(.cachesDirectory, name: "NASComicChapters"),
              let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.fileSizeKey]) else { return }
        cacheBytes = files.reduce(0) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
    }
    func removeCache(_ entry: NASComicEntry) throws {
        guard !busy else { throw NASComicError.busy }
        let file = try cacheURL(entry, config: configuration())
        if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
        refreshCacheSize()
    }
    struct CacheItem: Identifiable {
        let id: URL
        let name: String
        let size: Int64
    }
    func cacheItems() -> [CacheItem] {
        guard let folder = try? directory(.cachesDirectory, name: "NASComicChapters"),
              let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.fileSizeKey]) else { return [] }
        return files.filter { file in
            guard file.pathExtension == "cbz" else { return false }
            if let path = UserDefaults.standard.string(forKey: "NASComics.cachePath." + file.lastPathComponent) { return isComicVisible(path: path, isDirectory: false) }
            return true
        }.map { file in
            let name = UserDefaults.standard.string(forKey: "NASComics.cacheName." + file.lastPathComponent) ?? "章节缓存 " + String(file.lastPathComponent.prefix(8))
            return CacheItem(id: file, name: name, size: Int64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0))
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    func removeCacheFile(_ file: URL) throws {
        guard !busy else { throw NASComicError.busy }
        let folder = try directory(.cachesDirectory, name: "NASComicChapters")
        guard file.deletingLastPathComponent().standardizedFileURL == folder.standardizedFileURL, file.pathExtension == "cbz" else { throw NASComicError.invalidArchive }
        try FileManager.default.removeItem(at: file)
        UserDefaults.standard.removeObject(forKey: "NASComics.cacheName." + file.lastPathComponent)
        refreshCacheSize()
    }
    func cachedArchive(_ entry: NASComicEntry) async throws -> URL {
        let config = try configuration()
        let file = try cacheURL(entry, config: config)
        if FileManager.default.fileExists(atPath: file.path) { return file }
        guard !busy else { throw NASComicError.busy }
        refreshCacheSize()
        guard cacheBytes + max(entry.size, NASComicClient.maxFileBytes / 10) <= cacheLimit else { throw NASComicError.cacheFull }
        let client = try client(config)
        busy = true; status = "正在缓存 · " + entry.name; progress = nil
        activeClient = client
        let partial = file.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + ".part")
        defer {
            client.close(); activeClient = nil; busy = false; progress = nil
            try? FileManager.default.removeItem(at: partial)
            refreshCacheSize()
        }
        try await client.download(entry, to: partial)
        try Self.validateArchive(partial)
        try Task.checkCancellation()
        try FileManager.default.moveItem(at: partial, to: file)
        UserDefaults.standard.set(entry.path, forKey: "NASComics.cachePath." + file.lastPathComponent)
        UserDefaults.standard.set(entry.name, forKey: "NASComics.cacheName." + file.lastPathComponent)
        status = "章节已缓存，可离线阅读 · " + client.routeLabel
        return file
    }
    nonisolated static func validateArchive(_ url: URL) throws {
        let archive = try Archive(url: url, accessMode: .read)
        var pages = 0
        var expanded: UInt64 = 0
        var count = 0
        for entry in archive {
            count += 1
            expanded += entry.uncompressedSize
            guard count <= 20000, expanded <= UInt64(NASComicClient.maxFileBytes), entry.uncompressedSize <= 128 * 1024 * 1024,
                  entry.type != .symlink, !entry.path.hasPrefix("/"), !entry.path.split(separator: "/").contains("..") else { throw NASComicError.invalidArchive }
            if entry.type == .file, LocalFileManager.allowedPageExtensions.contains((entry.path as NSString).pathExtension.lowercased()) { pages += 1 }
        }
        guard pages > 0 else { throw NASComicError.invalidArchive }
    }
    func manga(folder: String, entries: [NASComicEntry]) throws -> AidokuRunner.Manga {
        let config = try configuration()
        let chapters = entries.filter { !$0.isDirectory }.enumerated().map { index, entry in
            AidokuRunner.Chapter(key: NASComicPaths.key(entry.path, fingerprint: config.fingerprint), title: (entry.name as NSString).deletingPathExtension,
                                 chapterNumber: Float(index + 1))
        }
        return .init(sourceKey: NASSourceRunner.sourceKey, key: NASComicPaths.key(folder, fingerprint: config.fingerprint),
                     title: folder.isEmpty ? "NAS 漫画" : (folder as NSString).lastPathComponent, contentRating: isComicExplicit(path: folder, isDirectory: true, config: config) ? .nsfw : .unknown, chapters: Array(chapters.reversed()))
    }
    func path(for key: String) throws -> String { try NASComicPaths.path(key, fingerprint: configuration().fingerprint) }
    func pages(chapter: AidokuRunner.Chapter) async throws -> [AidokuRunner.Page] {
        let path = try path(for: chapter.key)
        let folder = (path as NSString).deletingLastPathComponent
        let entries = try await entries(folder, refresh: false)
        guard let entry = entries.first(where: { $0.path == path && !$0.isDirectory }) else { throw NASSyncError.missingFolder }
        return try await onlinePages(entry)
    }
}
