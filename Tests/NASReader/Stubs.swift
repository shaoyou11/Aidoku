import Foundation
struct ChapterIdentifier { let sourceKey: String; let mangaKey: String; let chapterKey: String }
struct Page { var image: String?; var imageURL: String?; var marker: String }
enum AidokuRunner {
    struct Manga { let sourceKey: String; let key: String; var identifier: String { sourceKey + key } }
    struct Chapter: Equatable { let key: String; var language: String? = nil }
    struct Page {
        let marker: String
        func toOld(sourceId: String, chapterId: String, language: String?) -> LegacyPage { .init(marker: marker) }
    }
    class Source {
        var key = "source"; var languages = ["zh"]
        func getPageList(manga: Manga, chapter: Chapter) async throws -> [Page] { [.init(marker: "original")] }
    }
}
typealias LegacyPage = Page
@MainActor class ReaderTemporaryPageStore {
    func store(_ image: String, chapterKey: String, pageIndex: Int) async -> URL? { nil }
}
enum NASSourceRunner { static let sourceKey = "nas-webdav" }
enum NASConnection { static func message(for error: Error) -> String { "NAS failed" } }
@MainActor class DownloadManager {
    static let shared = DownloadManager()
    var staleCache = false
    func isChapterDownloaded(chapter: ChapterIdentifier) -> Bool { staleCache }
    func getDownloadedPages(for chapter: ChapterIdentifier) async -> [AidokuRunner.Page] { [] }
}
@MainActor class NASComicManager {
    static let shared = NASComicManager()
    var linked = false; var fail = false
    static func sourcePreferenceKey(_ id: String) -> String { "NASReaderTest." + id }
    func pages(chapter: AidokuRunner.Chapter) async throws -> [AidokuRunner.Page] {
        if fail { throw URLError(.cannotConnectToHost) }
        return [.init(marker: "nas-page-1"), .init(marker: "nas-page-2")]
    }
    func linkedPages(manga: AidokuRunner.Manga, chapter: AidokuRunner.Chapter) async throws -> [AidokuRunner.Page]? {
        linked ? try await pages(chapter: chapter) : nil
    }
}
