import AidokuRunner
import Foundation

extension AidokuRunner.Source {
    static func nas() -> AidokuRunner.Source {
        .init(url: nil, key: NASSourceRunner.sourceKey, name: "NAS 漫画库", version: 1, languages: ["multi"], urls: [], contentRating: .safe,
              config: .init(languageSelectType: .single), staticListings: [], staticFilters: [], staticSettings: [], runner: NASSourceRunner())
    }
}
final class NASSourceRunner: AidokuRunner.Runner {
    static let sourceKey = "nas-webdav"
    let features = AidokuRunner.SourceFeatures(
        providesListings: true, providesHome: false, dynamicFilters: false, dynamicSettings: false, dynamicListings: false,
        processesPages: false, providesImageRequests: false, providesPageDescriptions: false, providesAlternateCovers: false,
        providesBaseUrl: false, handlesNotifications: false, handlesDeepLinks: false, handlesBasicLogin: false, handlesWebLogin: false)

    func getSearchMangaList(query: String?, page: Int, filters: [AidokuRunner.FilterValue]) async throws -> AidokuRunner.MangaPageResult {
        let manager = await NASComicManager.shared
        let allEntries = try await manager.entries("")
        var entries: [NASComicEntry] = []
        for entry in allEntries where await manager.isComicVisible(path: entry.path, isDirectory: entry.isDirectory) { entries.append(entry) }
        var manga: [AidokuRunner.Manga] = []
        if entries.contains(where: { !$0.isDirectory }) { manga.append(try await manager.detailedManga(folder: "", entries: entries, allChapters: false)) }
        for entry in entries where entry.isDirectory {
            let children = (try? await manager.entries(entry.path, refresh: false)) ?? []
            let book = try await manager.detailedManga(folder: entry.path, entries: children, allChapters: false)
            if await PrivacyDisplayStore.shared.allows(book) { manga.append(book) }
        }
        if let query, !query.isEmpty { manga = manga.filter { $0.title.localizedCaseInsensitiveContains(query) } }
        return .init(entries: manga, hasNextPage: false)
    }
    func getMangaUpdate(manga: AidokuRunner.Manga, needsDetails: Bool, needsChapters: Bool) async throws -> AidokuRunner.Manga {
        let manager = await NASComicManager.shared
        let path = try await manager.path(for: manga.key)
        let entries = try await manager.entries(path)
        return try await manager.detailedManga(folder: path, entries: entries)
    }
    func getPageList(manga: AidokuRunner.Manga, chapter: AidokuRunner.Chapter) async throws -> [AidokuRunner.Page] {
        try await NASComicManager.shared.pages(chapter: chapter)
    }
    func getMangaList(listing: AidokuRunner.Listing, page: Int) async throws -> AidokuRunner.MangaPageResult {
        try await getSearchMangaList(query: nil, page: page, filters: [])
    }
}
