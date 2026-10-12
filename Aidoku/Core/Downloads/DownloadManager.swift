//
//  DownloadManager.swift
//  Aidoku
//
//  Created by Skitty on 5/2/22.
//

import AidokuRunner
import Foundation
import ImageIO
import UIKit
import ZIPFoundation

/*
 File Structure:
   Downloads/
     sourceId/
       mangaId/
         chapterId/
           .metadata.json     Chapter info stored here     (title, chapter number, volume number, source order)
           001.png
           002.png
           ...
 */

// global class to manage downloads
actor DownloadManager {
    static let shared = DownloadManager()

    static let directory = FileManager.default.documentDirectory.appendingPathComponent("Downloads", isDirectory: true)

    @MainActor
    private let cache: DownloadCache = .init()
    private let queue: DownloadQueue

    // for UI
    private var downloadedMangaCache: [DownloadedMangaInfo] = []
    private var lastCacheUpdate: Date = .distantPast
    private let cacheValidityDuration: TimeInterval = 60 // 1 minute

    init() {
        self.queue = DownloadQueue(cache: cache)
        if !Self.directory.exists {
            Self.directory.createDirectory()
        }
        Task {
            await self.queue.setOnCompletion { @Sendable in
                Task { @MainActor in
                    await self.invalidateDownloadedMangaCache()
                }
            }
        }
    }

    func loadQueueState() async {
        await queue.loadQueueState()

        // fetch loaded downloads to notify ui about
        let downloads = await queue.queue.flatMap(\.value)
        if !downloads.isEmpty {
            NotificationCenter.default.post(name: .downloadsQueued, object: downloads)
        }
    }

    func getDownloadedPages(for chapter: ChapterIdentifier) async -> [AidokuRunner.Page] {
        let directory = cache.directory(for: chapter)

        let archiveURL = directory.appendingPathExtension("cbz")
        if archiveURL.exists {
            return LocalFileManager.shared.readPages(from: archiveURL)
        } else {
            var descriptionFiles: [URL] = []

            var pages = directory.contents
                .sorted {
                    $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
                }
                .compactMap { url -> AidokuRunner.Page? in
                    guard !url.lastPathComponent.hasPrefix(".") else {
                        return nil
                    }
                    if LocalFileManager.allowedTextExtensions.contains(url.pathExtension) {
                        // add description file to list
                        if url.lastPathComponent.hasSuffix("desc.txt") {
                            descriptionFiles.append(url)
                            return nil
                        }
                        // otherwise, load file as text
                        let text: String? = try? String(contentsOf: url)
                        guard let text else { return nil }
                        return AidokuRunner.Page(content: .text(text))
                    } else if LocalFileManager.allowedImageExtensions.contains(url.pathExtension) {
                        // load file as image
                        return AidokuRunner.Page(content: .url(url: url, context: nil))
                    } else {
                        return nil
                    }
                }

            // load descriptions from files
            for descriptionFile in descriptionFiles {
                guard
                    let index = descriptionFile
                        .deletingPathExtension()
                        .lastPathComponent
                        .split(separator: ".", maxSplits: 1)
                        .first
                        .flatMap({ Int($0) }),
                    index > 0,
                    index <= pages.count
                else { break }
                pages[index - 1].hasDescription = true
                pages[index - 1].description = try? String(contentsOf: descriptionFile)
            }

            return pages
        }
    }

    @MainActor
    func isChapterDownloaded(chapter: ChapterIdentifier) -> Bool {
        cache.isChapterDownloaded(identifier: chapter)
    }

    @MainActor
    func hasDownloadedChapter(from identifier: MangaIdentifier) -> Bool {
        cache.hasDownloadedChapter(from: identifier)
    }

    func downloadsCount(for identifier: MangaIdentifier) -> Int {
        cache.directory(for: identifier)
            .contents
            .filter { ($0.isDirectory || $0.pathExtension == "cbz") && !$0.lastPathComponent.hasPrefix(".tmp") }
            .count
    }

    func hasQueuedDownloads() async -> Bool {
        await queue.hasQueuedDownloads()
    }

    nonisolated func getDownloadStatus(for chapter: ChapterIdentifier) -> DownloadStatus {
        let chapterDirectory = cache.directory(for: chapter)
        if chapterDirectory.exists || chapterDirectory.appendingPathExtension("cbz").exists {
            return .finished
        } else {
            let tmpDirectory = cache.tmpDirectory(for: chapter)
            if tmpDirectory.exists {
                return cache.hasFailureMarker(inTmpDirectory: tmpDirectory) ? .failed : .queued
            } else {
                return .none
            }
        }
    }

    nonisolated func getMangaDirectoryUrl(identifier: MangaIdentifier) -> URL? {
        let path = cache.directory(for: identifier).path
        return URL(string: "shareddocuments://\(path)")
    }

    func getCompressedFile(for chapter: ChapterIdentifier) -> URL? {
        let chapterDirectory = cache.directory(for: chapter)
        let chapterFile = chapterDirectory.appendingPathExtension("cbz")
        if chapterFile.exists {
            return chapterFile
        }
        // otherwise we can compress it ourselves
        let tmpFile = FileManager.default.temporaryDirectory.appendingPathComponent(chapterFile.lastPathComponent)
        do {
            try FileManager.default.zipItem(at: chapterDirectory, to: tmpFile, shouldKeepParent: false)
            return tmpFile
        } catch {
            return nil
        }
    }
}

// MARK: File Management

extension DownloadManager {
    /// Download all chapters for a manga.
    func downloadAll(manga: AidokuRunner.Manga) async {
        let allChapters = await CoreDataManager.shared.getChapters(mangaId: manga.identifier)

        var chaptersToDownload: [AidokuRunner.Chapter] = []

        for chapter in allChapters {
            guard !chapter.locked else { continue }
            let downloaded = await isChapterDownloaded(chapter: chapter.identifier)
            if !downloaded {
                chaptersToDownload.append(chapter.toNew())
            }
        }

        await download(manga: manga, chapters: chaptersToDownload.reversed())
    }

    /// Download unread chapters for a manga.
    func downloadUnread(manga: AidokuRunner.Manga) async {
        let readingHistory = await CoreDataManager.shared.getReadingHistory(mangaId: manga.identifier)
        let allChapters = await CoreDataManager.shared.getChapters(mangaId: manga.identifier)

        var chaptersToDownload: [AidokuRunner.Chapter] = []

        for chapter in allChapters {
            guard !chapter.locked else { continue }
            let isUnread = readingHistory[chapter.id] == nil || readingHistory[chapter.id]?.page != -1
            guard isUnread else { continue }
            let downloaded = await isChapterDownloaded(chapter: chapter.identifier)
            if !downloaded {
                chaptersToDownload.append(chapter.toNew())
            }
        }

        await download(manga: manga, chapters: chaptersToDownload.reversed())
    }

    /// Download given chapters from a manga.
    func download(manga: AidokuRunner.Manga, chapters: [AidokuRunner.Chapter]) async {
        let downloads = await queue.add(chapters: chapters, manga: manga, autoStart: true)
        NotificationCenter.default.post(
            name: .downloadsQueued,
            object: downloads
        )
        // Invalidate cache since new downloads may affect the list
        invalidateDownloadedMangaCache()
    }

    /// Remove downloads for specified chapters.
    func delete(chapters: [ChapterIdentifier]) async {
        for chapter in chapters {
            let directory = cache.directory(for: chapter)
            let archiveURL = directory.appendingPathExtension("cbz")
            let tmpDirectory = cache.tmpDirectory(for: chapter)

            if directory.exists || archiveURL.exists || tmpDirectory.exists {
                directory.removeItem()
                archiveURL.removeItem()
                tmpDirectory.removeItem()
                await cache.remove(chapter: chapter)

                // check if all chapters have been removed (then remove manga directory)
                let manga = chapter.mangaIdentifier
                let hasRemainingChapters = cache.directory(for: manga)
                    .contentsIncludingHidden
                    .contains {
                        guard $0.isDirectory || $0.pathExtension == "cbz" else { return false }
                        guard $0.lastPathComponent.hasPrefix(DownloadCache.tmpDirectoryPrefix) else { return true }
                        // a failed download counts as remaining
                        return cache.hasFailureMarker(inTmpDirectory: $0)
                    }
                if !hasRemainingChapters {
                    await deleteChapters(for: manga)
                } else {
                    NotificationCenter.default.post(name: .downloadRemoved, object: chapter)
                }
            }
        }
        // Invalidate cache for UI
        invalidateDownloadedMangaCache()
    }

    /// Remove all downloads from a manga.
    func deleteChapters(for manga: MangaIdentifier) async {
        await queue.cancelDownloads(for: manga)
        cache.directory(for: manga).removeItem()
        await cache.remove(manga: manga)

        // remove source directory if there are no more manga folders
        let sourceDirectory = cache.directory(sourceKey: manga.sourceKey)
        let hasRemainingManga = !sourceDirectory.contents.isEmpty
        if !hasRemainingManga {
            sourceDirectory.removeItem()
        }

        NotificationCenter.default.post(name: .downloadsRemoved, object: manga)
        // Invalidate cache for UI
        invalidateDownloadedMangaCache()
    }

    /// Remove all downloads.
    func deleteAll() async {
        await cache.removeAll()
    }
}

// MARK: Queue Control

extension DownloadManager {
    func isQueuePaused() async -> Bool {
        !(await queue.isRunning())
    }

    func getDownloadQueue() async -> [String: [Download]] {
        await queue.queue
    }

    func pauseDownloads() async {
        await queue.pause()
        NotificationCenter.default.post(name: .downloadsPaused, object: nil)
        // Invalidate cache since paused state may affect display
        invalidateDownloadedMangaCache()
    }

    func resumeDownloads() async {
        await queue.resume()
        NotificationCenter.default.post(name: .downloadsResumed, object: nil)
        // Invalidate cache since resumed state may affect display
        invalidateDownloadedMangaCache()
    }

    func cancelDownload(for chapter: ChapterIdentifier) async {
        await queue.cancelDownload(for: chapter)
        // Invalidate cache since cancelled downloads may affect display
        invalidateDownloadedMangaCache()
    }

    func cancelDownloads(for chapters: [ChapterIdentifier] = []) async {
        if chapters.isEmpty {
            await queue.cancelAll()
        } else {
            await queue.cancelDownloads(for: chapters)
        }
        // Invalidate cache since cancelled downloads may affect display
        invalidateDownloadedMangaCache()
    }

    func onProgress(for chapter: ChapterIdentifier, block: @Sendable @escaping (Int, Int) -> Void) async {
        await queue.onProgress(for: chapter, block: block)
    }

    func removeProgressBlock(for chapter: ChapterIdentifier) async {
        await queue.removeProgressBlock(for: chapter)
    }
}

// MARK: - Downloads UI Support
extension DownloadManager {
    /// Get all downloaded manga with metadata from CoreData if available
    func getAllDownloadedManga() async -> [DownloadedMangaInfo] {
        // Return cached result if still valid
        let now = Date()
        if now.timeIntervalSince(lastCacheUpdate) < cacheValidityDuration {
            return downloadedMangaCache
        }

        var downloadedManga: [DownloadedMangaInfo] = []

        // Ensure downloads directory exists
        guard Self.directory.exists else {
            downloadedMangaCache = []
            lastCacheUpdate = now
            return []
        }

        // Scan source directories
        let sourceDirectories = Self.directory.contents.filter { $0.isDirectory }

        for sourceDirectory in sourceDirectories {
            let sourceId = sourceDirectory.lastPathComponent
            let mangaDirectories = sourceDirectory.contents.filter { $0.isDirectory }

            for mangaDirectory in mangaDirectories {
                let mangaId = mangaDirectory.lastPathComponent

                // Count chapters and calculate total size, including from failed downloads
                let chapterDirectories = mangaDirectory.contentsIncludingHidden.filter {
                    guard $0.isDirectory || $0.pathExtension == "cbz" else { return false }
                    guard $0.lastPathComponent.hasPrefix(DownloadCache.tmpDirectoryPrefix) else { return true }
                    return cache.hasFailureMarker(inTmpDirectory: $0)
                }

                guard !chapterDirectories.isEmpty else { continue }

                let totalSize = await calculateDirectorySize(mangaDirectory, includingHidden: true)
                let chapterCount = chapterDirectories.count

                // Try to load metadata from the manga directory first
                let firstComicInfo = findComicInfo(in: mangaDirectory)
                let extraData = firstComicInfo?.extraData()

                // Fallback to CoreData only if no stored metadata exists
                let mangaMetadata = if let firstComicInfo {
                    (
                        title: firstComicInfo.series,
                        coverUrl: mangaDirectory.appendingPathComponent("cover.png").absoluteString,
                        isInLibrary: await withCheckedContinuation { continuation in
                            CoreDataManager.shared.container.performBackgroundTask { context in
                                let isInLibrary = CoreDataManager.shared.hasLibraryManga(
                                    mangaId: .init(sourceKey: sourceId, mangaKey: extraData?.mangaKey ?? mangaId),
                                    context: context
                                )
                                continuation.resume(returning: isInLibrary)
                            }
                        },
                        actualMangaId: extraData?.mangaKey ?? mangaId
                    )
                } else {
                    await withCheckedContinuation { continuation in
                        CoreDataManager.shared.container.performBackgroundTask { context in
                            // First try direct lookup with the directory name
                            var mangaObject = CoreDataManager.shared.getManga(
                                mangaId: .init(sourceKey: sourceId, mangaKey: extraData?.mangaKey ?? mangaId),
                                context: context
                            )
                            var isInLibrary = CoreDataManager.shared.hasLibraryManga(
                                mangaId: .init(sourceKey: sourceId, mangaKey: extraData?.mangaKey ?? mangaId),
                                context: context
                            )

                            // If not found, try to find a manga whose sanitized ID matches the directory name
                            if mangaObject == nil {
                                let allMangaForSource = CoreDataManager.shared.getManga(context: context)
                                    .filter { $0.sourceId == sourceId }

                                for candidateManga in allMangaForSource {
                                    let candidateId = candidateManga.id
                                    if candidateId.directoryName == mangaId {
                                        mangaObject = candidateManga
                                        isInLibrary = CoreDataManager.shared.hasLibraryManga(
                                            mangaId: .init(sourceKey: sourceId, mangaKey: candidateId),
                                            context: context
                                        )
                                        break
                                    }
                                }
                            }

                            let result = (
                                title: mangaObject?.title,
                                coverUrl: mangaObject?.cover,
                                isInLibrary: isInLibrary,
                                actualMangaId: mangaObject?.id ?? mangaId
                            )
                            continuation.resume(returning: result)
                        }
                    }
                }

                let downloadedMangaInfo = DownloadedMangaInfo(
                    sourceId: sourceId,
                    mangaId: mangaMetadata.actualMangaId, // Use the actual manga ID, not directory name
                    directoryMangaId: mangaId, // Keep directory name for file access
                    title: mangaMetadata.title,
                    coverUrl: mangaMetadata.coverUrl,
                    totalSize: totalSize,
                    chapterCount: chapterCount,
                    isInLibrary: mangaMetadata.isInLibrary
                )

                downloadedManga.append(downloadedMangaInfo)
            }
        }

        // Sort by source ID, then by title/manga ID
        downloadedManga.sort { lhs, rhs in
            if lhs.sourceId != rhs.sourceId {
                return lhs.sourceId < rhs.sourceId
            }
            return lhs.displayTitle.localizedCaseInsensitiveCompare(rhs.displayTitle) == .orderedAscending
        }

        // Cache the result
        downloadedMangaCache = downloadedManga
        lastCacheUpdate = now

        return downloadedManga
    }

    /// Get downloaded chapters for a specific manga
    func getDownloadedChapters(for identifier: MangaIdentifier) async -> [DownloadedChapterInfo] {
        let mangaDirectory = cache.directory(for: identifier)
        guard mangaDirectory.exists else { return [] }

        let chapterDirectories = mangaDirectory.contents.filter {
            ($0.isDirectory || $0.pathExtension == "cbz") && !$0.lastPathComponent.hasPrefix(DownloadCache.tmpDirectoryPrefix)
        }
        let failedDirectories = mangaDirectory.contentsIncludingHidden.filter {
            $0.isDirectory && cache.hasFailureMarker(inTmpDirectory: $0)
        }

        var chapters: [DownloadedChapterInfo] = []
        let entries = chapterDirectories.map { ($0, false) } + failedDirectories.map { ($0, true) }

        for (chapterDirectory, failed) in entries {
            let chapterId = if failed {
                String(chapterDirectory.lastPathComponent.dropFirst(DownloadCache.tmpDirectoryPrefix.count))
            } else {
                chapterDirectory.isDirectory ? chapterDirectory.lastPathComponent : chapterDirectory.deletingPathExtension().lastPathComponent
            }
            let size = await calculateDirectorySize(chapterDirectory)

            // Get directory creation date as download date
            let attributes = try? FileManager.default.attributesOfItem(atPath: chapterDirectory.path)
            let downloadDate = attributes?[.creationDate] as? Date

            // Try to load metadata from the chapter directory
            let metadata = getComicInfo(in: chapterDirectory)

            let chapterInfo = DownloadedChapterInfo(
                chapterId: chapterId,
                title: metadata?.title,
                chapterNumber: metadata?.number.flatMap { Float($0) },
                volumeNumber: metadata?.volume.flatMap { Float($0) },
                size: size,
                downloadDate: downloadDate,
                failed: failed,
                chapter: metadata?.toChapter()
            )

            chapters.append(chapterInfo)
        }

        // Sort chapters by ID
        return chapters.sorted { lhs, rhs in
            // Try to sort numerically if possible, otherwise alphabetically
            if let lhsNum = Double(lhs.chapterId), let rhsNum = Double(rhs.chapterId) {
                return lhsNum < rhsNum
            }
            return lhs.chapterId.localizedStandardCompare(rhs.chapterId) == .orderedAscending
        }
    }

    /// Save chapter metadata to ComicInfo.xml.
    func saveChapterMetadata(manga: AidokuRunner.Manga, chapter: AidokuRunner.Chapter, to directory: URL) {
        let xml = ComicInfo.load(manga: manga, chapter: chapter).export()
        guard let data = xml.data(using: .utf8) else { return }
        do {
            let metadataURL = directory.appendingPathComponent("ComicInfo.xml")
            try data.write(to: metadataURL)
        } catch {
            LogManager.logger.error("Failed to save chapter metadata: \(error)")
        }
    }

    /// Load chapter metadata from chapter directory.
    private func getComicInfo(in directory: URL) -> ComicInfo? {
        do {
            if directory.pathExtension == "cbz" {
                return ComicInfo.load(from: directory)
            }

            guard directory.isDirectory else { return nil }

            let xmlURL = directory.appendingPathComponent("ComicInfo.xml")
            if xmlURL.exists {
                let data = try Data(contentsOf: xmlURL)
                if
                    let string = String(data: data, encoding: .utf8),
                    let comicInfo = ComicInfo.load(xmlString: string)
                {
                    return comicInfo
                }
            }

            return nil
        } catch {
            LogManager.logger.error("Failed to load chapter metadata: \(error)")
            return nil
        }
    }

    /// Load metadata from manga directory.
    private func findComicInfo(in directory: URL) -> ComicInfo? {
        for child in directory.contents where child.isDirectory || child.pathExtension == "cbz" {
            if let info = getComicInfo(in: child) { return info }
        }

        return nil
    }

    func downloadedDetails(_ manga: DownloadedMangaInfo) -> AidokuRunner.Manga {
        let directory = cache.directory(for: manga.mangaIdentifier)
        var details = findComicInfo(in: directory)?.copy(into: manga.toManga()) ?? manga.toManga()
        let savedCover = directory.appendingPathComponent("cover.png")
        let preview = directory.appendingPathComponent("cover-preview.jpg")
        if savedCover.exists { details.cover = savedCover.absoluteString }
        else if preview.exists { details.cover = preview.absoluteString }
        else {
            // Recover a local thumbnail without depending on the original image server.
            for child in directory.contents.sorted(by: { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }) {
                var bytes: Data?
                if child.pathExtension == "cbz", let archive = try? Archive(url: child, accessMode: .read),
                   let first = archive.filter({ $0.type == .file && LocalFileManager.allowedPageExtensions.contains(($0.path as NSString).pathExtension.lowercased()) })
                    .sorted(by: { $0.path.localizedStandardCompare($1.path) == .orderedAscending }).first,
                   first.uncompressedSize <= 64 * 1024 * 1024 {
                    var data = Data()
                    if (try? archive.extract(first, consumer: { data.append($0) })) != nil { bytes = data }
                } else if child.isDirectory,
                          let first = child.contents.filter({ LocalFileManager.allowedPageExtensions.contains($0.pathExtension.lowercased()) })
                            .sorted(by: { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }).first,
                          (try? first.resourceValues(forKeys: [.fileSizeKey]).fileSize).map({ $0 <= 64 * 1024 * 1024 }) == true {
                    bytes = try? Data(contentsOf: first)
                }
                if let bytes, let source = CGImageSourceCreateWithData(bytes as CFData, nil),
                   let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceThumbnailMaxPixelSize: 480, kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary),
                   let jpeg = UIImage(cgImage: image).jpegData(compressionQuality: 0.82) {
                    if (try? jpeg.write(to: preview, options: .atomic)) != nil { details.cover = preview.absoluteString }
                    break
                }
            }
        }
        return details
    }

    /// Calculate the total size of a directory in bytes.
    private func calculateDirectorySize(_ directory: URL, includingHidden: Bool = false) async -> Int64 {
        guard directory.exists else { return 0 }

        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                var totalSize: Int64 = 0

                if directory.isDirectory {
                    if let enumerator = FileManager.default.enumerator(
                        at: directory,
                        includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
                        options: includingHidden ? [] : [.skipsHiddenFiles]
                    ) {
                        for case let fileURL as URL in enumerator {
                            do {
                                let resourceValues = try fileURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
                                if resourceValues.isRegularFile == true {
                                    totalSize += Int64(resourceValues.fileSize ?? 0)
                                }
                            } catch {
                                // Skip files that can't be accessed
                                continue
                            }
                        }
                    }
                } else {
                    let resourceValues = try? directory.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
                    if let resourceValues, resourceValues.isRegularFile == true {
                        totalSize = Int64(resourceValues.fileSize ?? 0)
                    }
                }

                continuation.resume(returning: totalSize)
            }
        }
    }

    /// Get formatted total download size string
    func getFormattedTotalDownloadedSize() async -> String {
        let totalSize = if Self.directory.exists {
            await calculateDirectorySize(Self.directory, includingHidden: true)
        } else {
            Int64(0)
        }
        return ByteCountFormatter.string(fromByteCount: totalSize, countStyle: .file)
    }

    /// Invalidate the downloaded manga cache (call when downloads are added/removed)
    private func invalidateDownloadedMangaCache() {
        lastCacheUpdate = .distantPast
    }
}

extension DownloadManager {
    /// Check if there is any old metadata files that need migration.
    func checkForOldMetadata() -> Bool {
        for sourceDirectory in Self.directory.contents where sourceDirectory.isDirectory {
            for mangaDirectory in sourceDirectory.contents where mangaDirectory.isDirectory {
                if mangaDirectory.appendingPathComponent(".manga_metadata.json").exists {
                    return true
                }
                for chapterDirectory in mangaDirectory.contents where chapterDirectory.isDirectory {
                    if chapterDirectory.appendingPathComponent(".metadata.json").exists {
                        return true
                    }
                }
            }
        }
        return false
    }

    /// Migrate old metadata files to new format.
    func migrateOldMetadata() {
        for sourceDirectory in Self.directory.contents where sourceDirectory.isDirectory {
            for mangaDirectory in sourceDirectory.contents where mangaDirectory.isDirectory {
                let mangaMetadataUrl = mangaDirectory.appendingPathComponent(".manga_metadata.json")
                var seriesTitle: String?
                if mangaMetadataUrl.exists {
                    if
                        let data = try? Data(contentsOf: mangaMetadataUrl),
                        let metadata = try? JSONDecoder().decode(MangaMetadata.self, from: data)
                    {
                        // save series title for chapter ComicInfo
                        seriesTitle = metadata.title
                        // save cover image data as cover.png
                        if
                            let thumbnailBase64 = metadata.thumbnailBase64,
                            let imageData = Data(base64Encoded: thumbnailBase64)
                        {
                            try? imageData.write(to: mangaDirectory.appendingPathComponent("cover.png"))
                        }
                    }
                    mangaMetadataUrl.removeItem()
                }
                for chapterDirectory in mangaDirectory.contents where chapterDirectory.isDirectory {
                    let chapterMetadataUrl = chapterDirectory.appendingPathComponent(".metadata.json")
                    if chapterMetadataUrl.exists {
                        if
                            let data = try? Data(contentsOf: chapterMetadataUrl),
                            let metadata = try? JSONDecoder().decode(ChapterMetadata.self, from: data)
                        {
                            let xml = ComicInfo(
                                title: metadata.title,
                                series: seriesTitle,
                                number: metadata.chapterNumber.flatMap { String($0) },
                                volume: metadata.volumeNumber.flatMap { Int(floor($0)) }
                            ).export()
                            guard let data = xml.data(using: .utf8) else { continue }
                            try? data.write(to: chapterDirectory.appendingPathComponent("ComicInfo.xml"))
                        }
                        chapterMetadataUrl.removeItem()
                    }
                }
            }
        }
        invalidateDownloadedMangaCache()
    }

    private struct ChapterMetadata: Codable {
        let title: String?
        let chapterNumber: Float?
        let volumeNumber: Float?
        var chapter: AidokuRunner.Chapter?
    }

    private struct MangaMetadata: Codable {
        let mangaId: String?
        let title: String?
        let cover: String?
        let thumbnailBase64: String?
        let description: String?
    }
}

extension DownloadManager {
    /// Called only after the remote archive, first page and chapter association have been verified.
    func removeVerifiedNASDownload(_ chapter: ChapterIdentifier, verifiedArchive: URL) async throws {
        guard !cache.tmpDirectory(for: chapter).exists else { throw NASComicError.localChanged }
        let directory = cache.directory(for: chapter)
        let files = try NASComicVerification.localFiles(directory: directory, archive: verifiedArchive)
        // Remove explicit files one at a time. Preserve manga metadata, cover and unrelated chapters.
        for file in files { try FileManager.default.removeItem(at: file) }
        if directory.exists {
            // Only empty directories are removed; never recursively remove a chapter or manga folder.
            let children = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isDirectoryKey])?
                .allObjects.compactMap { $0 as? URL }.filter { $0.isDirectory } ?? []
            for child in children.sorted(by: { $0.path.count > $1.path.count }) { _ = rmdir(child.path) }
            guard rmdir(directory.path) == 0 else { throw NASComicError.localChanged }
        }
        await cache.remove(chapter: chapter)
        NotificationCenter.default.post(name: .downloadRemoved, object: chapter)
        invalidateDownloadedMangaCache()
    }

    /// Make a private, unique copy for a NAS transfer without moving or deleting the local download.
    func makeNASArchive(for chapter: ChapterIdentifier) throws -> URL {
        let source = cache.directory(for: chapter)
        let archive = source.appendingPathExtension("cbz")
        let target = FileManager.default.temporaryDirectory.appendingPathComponent("nas-" + UUID().uuidString + ".cbz")
        if archive.exists {
            try FileManager.default.copyItem(at: archive, to: target)
        } else {
            guard source.exists, !cache.tmpDirectory(for: chapter).exists else { throw NASComicError.invalidArchive }
            try FileManager.default.zipItem(at: source, to: target, shouldKeepParent: false)
        }
        return target
    }
}
