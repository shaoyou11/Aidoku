import CoreData
import Foundation

@main struct Tests {
    static func expect(_ value: Bool, _ message: String) { if !value { fatalError(message) } }
    @MainActor static func main() throws {
        let manager = NASSyncManager.shared
        let context = CoreDataManager.shared.context
        let library = NASSyncValue.library(.init(sourceID: "source", mangaID: "manga", title: "Title", author: "Author",
            cover: nil, dateAdded: Date(timeIntervalSince1970: 100), categories: ["收藏"]))
        let progress = NASSyncValue.progress(.init(sourceID: "source", mangaID: "manga", chapterID: "chapter", page: 20,
            total: 50, completed: false, dateRead: Date(timeIntervalSince1970: 200), scrollPosition: 0.75))
        let incoming = [library.key: library, progress.key: progress]
        var remote = NASSyncDocument()
        remote.capture(incoming, device: "remote", now: Date(timeIntervalSince1970: 200))
        _ = try manager.apply(remote, expected: [:], context: context)
        expect(try manager.snapshot(context) == incoming, "imported rows must round trip without becoming false local edits")
        _ = try manager.apply(remote, expected: incoming, context: context)
        expect(try context.count(for: LibraryMangaObject.fetchRequest()) == 1, "idempotent library import")
        expect(try context.count(for: HistoryObject.fetchRequest()) == 1, "idempotent history import")
        let history = try context.fetch(HistoryObject.fetchRequest()).first!
        history.progress = 25
        history.dateRead = Date(timeIntervalSince1970: 300)
        try context.save()
        let applied = try manager.apply(remote, expected: incoming, context: context)
        expect(!applied.contains(progress.key) && history.progress == 25, "edits during network request must be preserved")
        let current = try manager.snapshot(context)
        var deletion = remote
        deletion.capture([:], device: "remote", now: Date(timeIntervalSince1970: 400))
        _ = try manager.apply(deletion, expected: current, context: context)
        expect(try manager.snapshot(context).isEmpty, "deleted history must not reappear on next snapshot")
        expect(try context.count(for: NSFetchRequest<MangaObject>(entityName: "Manga")) == 1, "membership removal must preserve manga data")
        expect(try context.count(for: HistoryObject.fetchRequest()) == 1, "history removal must preserve row for reading sessions")
        var next = deletion
        next.capture(try manager.snapshot(context), device: "local", now: Date(timeIntervalSince1970: 500))
        expect(next == deletion, "applied tombstones must remain stable")
        _ = try manager.apply(remote, expected: [:], context: context)
        expect(try manager.snapshot(context) == incoming, "explicit re-add restores membership and progress")
        print("PASS: 9 database integration checks using the actual compiled Core Data model")
    }
}
