import CoreData
import Foundation

struct MangaIdentifier { let sourceKey: String; let mangaKey: String }
struct ChapterIdentifier { let sourceKey: String; let mangaKey: String; let chapterKey: String }
enum LocalSourceRunner { static let sourceKey = "local" }
enum AppSettings {
    struct Flag { func get() -> Bool { false } }
    struct General { let icloudSync = Flag() }
    static let general = General()
}
extension Notification.Name {
    static let updateLibrary = Self("updateLibrary")
    static let updateHistory = Self("updateHistory")
    static let updateCategories = Self("updateCategories")
}
@objc(MangaObject) public class MangaObject: NSManagedObject {
    @NSManaged var id: String
    @NSManaged var sourceId: String
    @NSManaged var title: String
    @NSManaged var author: String?
    @NSManaged var cover: String?
    @NSManaged var fileInfo: NSManagedObject?
}
@objc(CategoryObject) public class CategoryObject: NSManagedObject {
    @NSManaged var title: String?
    class func fetchRequest() -> NSFetchRequest<CategoryObject> { .init(entityName: "Category") }
}
@objc(ChapterObject) public class ChapterObject: NSManagedObject {
    @NSManaged var fileInfo: NSManagedObject?
}
@objc(ReadingSessionObject) public class ReadingSessionObject: NSManagedObject {}

final class CoreDataManager: @unchecked Sendable {
    static let shared = CoreDataManager()
    let container: NSPersistentContainer
    @MainActor var context: NSManagedObjectContext { container.viewContext }
    init() {
        let model = NSManagedObjectModel(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))!
        let classes: [String: AnyClass] = ["Manga": MangaObject.self, "LibraryManga": LibraryMangaObject.self,
            "History": HistoryObject.self, "Category": CategoryObject.self, "Chapter": ChapterObject.self,
            "ReadingSession": ReadingSessionObject.self]
        for entity in model.entities { entity.managedObjectClassName = NSStringFromClass(classes[entity.name!] ?? NSManagedObject.self) }
        container = NSPersistentContainer(name: "Tests", managedObjectModel: model)
        let description = NSPersistentStoreDescription()
        description.type = NSSQLiteStoreType
        description.url = FileManager.default.temporaryDirectory.appendingPathComponent("aidoku-sync-test-" + UUID().uuidString + ".sqlite")
        container.persistentStoreDescriptions = [description]
        container.loadPersistentStores { _, error in precondition(error == nil) }
        container.viewContext.automaticallyMergesChangesFromParent = true
    }
    func getManga(mangaId: MangaIdentifier, context: NSManagedObjectContext) -> MangaObject? {
        let request = NSFetchRequest<MangaObject>(entityName: "Manga")
        request.predicate = NSPredicate(format: "sourceId == %@ AND id == %@", mangaId.sourceKey, mangaId.mangaKey)
        return try! context.fetch(request).first
    }
    func getLibraryManga(mangaId: MangaIdentifier, context: NSManagedObjectContext) -> LibraryMangaObject? {
        let request = LibraryMangaObject.fetchRequest()
        request.predicate = NSPredicate(format: "manga.sourceId == %@ AND manga.id == %@", mangaId.sourceKey, mangaId.mangaKey)
        return try! context.fetch(request).first
    }
    func getHistory(chapterId: ChapterIdentifier, context: NSManagedObjectContext) -> HistoryObject? {
        let request = HistoryObject.fetchRequest()
        request.predicate = NSPredicate(format: "sourceId == %@ AND mangaId == %@ AND chapterId == %@", chapterId.sourceKey, chapterId.mangaKey, chapterId.chapterKey)
        return try! context.fetch(request).first
    }
    func getOrCreateHistory(chapterId: ChapterIdentifier, context: NSManagedObjectContext) -> HistoryObject {
        if let existing = getHistory(chapterId: chapterId, context: context) { return existing }
        let history = HistoryObject(context: context)
        history.sourceId = chapterId.sourceKey
        history.mangaId = chapterId.mangaKey
        history.chapterId = chapterId.chapterKey
        return history
    }
}
