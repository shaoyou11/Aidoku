import Foundation
@main struct Tests {
    @MainActor static func main() async {
        let chapter = AidokuRunner.Chapter(key: "chapter")
        DownloadManager.shared.staleCache = true
        let direct = ReaderPagedViewModel(source: nil, manga: .init(sourceKey: NASSourceRunner.sourceKey, key: "book"))
        await direct.loadPages(chapter: chapter)
        precondition(direct.pages.count == 2 && direct.pages[0].marker == "nas-page-1", "NAS must load without a source object or local downloads, even with a stale download flag")
        let nextChapter = AidokuRunner.Chapter(key: "next-chapter")
        let preloaded = await direct.preload(chapter: nextChapter)
        precondition(preloaded.count == 2 && direct.preloadedChapter == nextChapter, "upstream preload result must preserve NAS page routing")
        let repeated = await direct.preload(chapter: nextChapter)
        precondition(repeated.count == 2, "cached preload must return the same pages")
        await direct.loadPages(chapter: nextChapter)
        precondition(direct.chapter == nextChapter && direct.pages.count == 2, "loading a preloaded chapter must retain its NAS pages")
        NASComicManager.shared.fail = true
        let failedPreload = await direct.preload(chapter: .init(key: "offline-chapter"))
        precondition(failedPreload.isEmpty && direct.preloadedChapter == nil, "failed NAS preload must not cache an empty chapter as completed")
        NASComicManager.shared.fail = false
        NASComicManager.shared.linked = true
        let linked = ReaderPagedViewModel(source: nil, manga: .init(sourceKey: "local", key: "book"))
        await linked.loadPages(chapter: chapter)
        precondition(linked.pages.count == 2, "linked imported manga must remain readable after local removal")
        NASComicManager.shared.linked = false
        DownloadManager.shared.staleCache = false
        let original = ReaderPagedViewModel(source: .init(), manga: .init(sourceKey: "source", key: "book"))
        await original.loadPages(chapter: chapter)
        precondition(original.pages.first?.marker == "original", "unuploaded chapter must retain original source")
        NASComicManager.shared.linked = true
        let preference = NASComicManager.sourcePreferenceKey(original.manga.identifier)
        UserDefaults.standard.set("original", forKey: preference)
        defer { UserDefaults.standard.removeObject(forKey: preference) }
        let forcedOriginal = ReaderPagedViewModel(source: .init(), manga: original.manga)
        await forcedOriginal.loadPages(chapter: chapter)
        precondition(forcedOriginal.pages.first?.marker == "original", "explicit original-source choice must remain effective")
        print("PASS: production reader routing without local downloads/source initialization, stale download isolation, unuploaded chapters and manual source choice")
    }
}
