import CoreData
import CryptoKit
import Security
import UIKit

@MainActor
final class NASSyncManager: ObservableObject {
    static let shared = NASSyncManager()
    @Published private(set) var busy = false
    @Published private(set) var status = "尚未同步"
    @Published private(set) var lastSync: Date?
    private var automaticTask: Task<Void, Never>?
    private static let service = (Bundle.main.bundleIdentifier ?? "Aidoku") + ".NASConnection"
    private static let deviceKey = "NASSync.device"
    private static let automaticKey = "NASSync.automatic"

    var automatic: Bool {
        get { UserDefaults.standard.bool(forKey: Self.automaticKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.automaticKey) }
    }

    func loadConnection() throws -> NASConnection {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: "connection",
            kSecReturnData as String: true
        ]
        var item: CFTypeRef?
        let result = SecItemCopyMatching(query as CFDictionary, &item)
        if result == errSecItemNotFound { return .init() }
        guard result == errSecSuccess, let data = item as? Data,
              let connection = try? JSONDecoder().decode(NASConnection.self, from: data) else {
            throw NASSyncError.keychain
        }
        return connection
    }

    func saveConnection(_ connection: NASConnection) throws {
        _ = try connection.fileURL()
        guard !connection.username.isEmpty, !connection.username.contains(":"), !connection.password.isEmpty else {
            throw NASSyncError.authentication
        }
        let data = try JSONEncoder().encode(connection)
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: "connection"
        ]
        var result = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if result == errSecItemNotFound {
            query[kSecValueData as String] = data
            query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            result = SecItemAdd(query as CFDictionary, nil)
        }
        guard result == errSecSuccess else { throw NASSyncError.keychain }
        lastSync = nil
        status = "连接信息已保存"
    }

    func startAutomaticSync() {
        guard automaticTask == nil, automatic else { return }
        automaticTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.automatic else { break }
                await self.sync()
                do { try await Task.sleep(nanoseconds: 60_000_000_000) } catch { break }
            }
        }
    }

    func stopAutomaticSync() {
        automaticTask?.cancel()
        automaticTask = nil
    }

    func sync(restoreOnly: Bool = false) async {
        guard !busy else { return }
        guard !AppSettings.general.icloudSync.get() else {
            status = "请先关闭 iCloud 同步，再使用 NAS 同步。"
            return
        }
        busy = true
        status = restoreOnly ? "正在从 NAS 恢复…" : "正在同步…"
        defer { busy = false }
        do {
            let connection = try loadConnection()
            let url = try connection.fileURL()
            let directory = try stateDirectory(url: url, username: connection.username)
            let stateURL = directory.appendingPathComponent("local-state.json")
            var local = try loadState(stateURL)
            let context = CoreDataManager.shared.context
            if context.hasChanges { try context.save() }
            let snapshot = try snapshot(context)
            local.capture(snapshot, device: deviceID(), now: Date())
            try saveState(local, to: stateURL) // persist unsent edits before touching the network
            let client = NASWebDAVClient(connection: connection)
            defer { client.close() }
            let merged: NASSyncDocument
            if restoreOnly {
                let remote = try await client.read()
                guard remote.etag != nil, remote.document.records.values.contains(where: { $0.value != nil }) else {
                    status = "NAS 中没有可恢复的书架或阅读进度，请确认选择了原来的同步文件夹。"
                    return
                }
                merged = local.restoring(remote.document)
                try merged.validate()
            } else {
                merged = try await client.synchronize(local)
            }
            try Task.checkCancellation()
            // Keep a recoverable local copy before any inbound changes. Never contains credentials.
            try saveState(local, to: directory.appendingPathComponent(restoreOnly ? "before-last-restore.json" : "before-last-sync.json"))
            if context.hasChanges { try context.save() }
            let transaction = CoreDataManager.shared.container.newBackgroundContext()
            transaction.mergePolicy = NSErrorMergePolicy
            let applied = try transaction.performAndWait {
                try self.apply(merged, expected: snapshot, context: transaction)
            }
            // Do not swallow edits made while GET/PUT was in flight.
            for key in applied { local.records[key] = merged.records[key] }
            try saveState(local, to: stateURL)
            NotificationCenter.default.post(name: .updateLibrary, object: nil)
            NotificationCenter.default.post(name: .updateHistory, object: nil)
            NotificationCenter.default.post(name: .updateCategories, object: nil)
            lastSync = Date()
            if restoreOnly {
                status = "恢复完成，已合并 NAS 书架和阅读进度；未上传修改 NAS 文件。"
            } else {
                status = applied.count == merged.records.count ? "同步完成" : "同步完成，期间的新修改将在下次同步"
            }
        } catch is CancellationError {
            status = "同步已暂停，下次打开 App 时重试"
        } catch let error as NASSyncError {
            status = error.localizedDescription
        } catch {
            // URLSession/Core Data errors can embed private server addresses. Never display raw errors.
            status = "同步未完成，请检查网络、NAS 证书和本机存储后重试。本机修改已保留。"
        }
    }

    private func deviceID() -> String {
        if let value = UserDefaults.standard.string(forKey: Self.deviceKey) { return value }
        let value = UUID().uuidString
        UserDefaults.standard.set(value, forKey: Self.deviceKey)
        return value
    }

    private func stateDirectory(url: URL, username: String) throws -> URL {
        let digest = SHA256.hash(data: Data((url.absoluteString + "\n" + username).utf8))
        let name = digest.map { String(format: "%02x", $0) }.joined()
        let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let directory = base.appendingPathComponent("NASSync").appendingPathComponent(name)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func loadState(_ url: URL) throws -> NASSyncDocument {
        guard FileManager.default.fileExists(atPath: url.path) else { return .init() }
        guard let data = try? Data(contentsOf: url),
              let state = try? JSONDecoder().decode(NASSyncDocument.self, from: data) else {
            throw NASSyncError.localStorage
        }
        try state.validate()
        return state
    }

    private func saveState(_ state: NASSyncDocument, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(state).write(to: url, options: [.atomic, .completeFileProtection])
    }

    nonisolated private func snapshot(_ context: NSManagedObjectContext) throws -> [String: NASSyncValue] {
        var result: [String: NASSyncValue] = [:]
        for library in try context.fetch(LibraryMangaObject.fetchRequest()) {
            guard let manga = library.manga, manga.fileInfo == nil, manga.sourceId != LocalSourceRunner.sourceKey else { continue }
            let categories = (library.categories?.allObjects as? [CategoryObject] ?? []).compactMap(\.title).sorted()
            let value = NASSyncValue.library(.init(
                sourceID: manga.sourceId, mangaID: manga.id, title: manga.title,
                author: manga.author, cover: manga.cover, dateAdded: library.dateAdded, categories: categories
            ))
            guard result[value.key] == nil else { throw NASSyncError.localStorage }
            result[value.key] = value
        }
        for history in try context.fetch(HistoryObject.fetchRequest()) {
            if history.sourceId == LocalSourceRunner.sourceKey || history.chapter?.fileInfo != nil { continue }
            if !history.completed && history.progress < 0 && history.dateRead == Date.distantPast { continue }
            let value = NASSyncValue.progress(.init(
                sourceID: history.sourceId, mangaID: history.mangaId, chapterID: history.chapterId,
                page: Int(history.progress), total: Int(history.total), completed: history.completed,
                dateRead: history.dateRead ?? .distantPast, scrollPosition: history.scrollPosition?.doubleValue
            ))
            guard result[value.key] == nil else { throw NASSyncError.localStorage }
            result[value.key] = value
        }
        return result
    }

    /// A separate context commits inbound changes atomically; conflicting database saves fail safely.
    nonisolated private func apply(
        _ document: NASSyncDocument, expected: [String: NASSyncValue], context: NSManagedObjectContext
    ) throws -> Set<String> {
        let current = try snapshot(context)
        var applied = Set<String>()
        // Membership must be available before updating manga.lastRead from progress.
        let keys = document.records.keys.sorted { lhs, rhs in
            ((try? NASSyncDocument.parts(lhs).first) ?? "") < ((try? NASSyncDocument.parts(rhs).first) ?? "")
        }
        for key in keys {
            guard current[key] == expected[key], let record = document.records[key] else { continue }
            applied.insert(key)
            guard current[key] != record.value else { continue }
            let parts = try NASSyncDocument.parts(key)
            guard parts[1] != LocalSourceRunner.sourceKey else { throw NASSyncError.invalidDocument }
            let mangaID = MangaIdentifier(sourceKey: parts[1], mangaKey: parts[2])
            switch record.value {
            case .library(let item):
                let manga: MangaObject
                if let existing = CoreDataManager.shared.getManga(mangaId: mangaID, context: context) {
                    manga = existing
                } else {
                    manga = MangaObject(context: context)
                    manga.sourceId = item.sourceID
                    manga.id = item.mangaID
                }
                manga.title = item.title
                manga.author = item.author
                manga.cover = item.cover
                let library = CoreDataManager.shared.getLibraryManga(mangaId: mangaID, context: context)
                    ?? LibraryMangaObject(context: context)
                library.manga = manga
                library.dateAdded = item.dateAdded
                let existing = try context.fetch(CategoryObject.fetchRequest())
                library.categories = NSSet(array: item.categories.map { title in
                    if let category = existing.first(where: { $0.title == title }) { return category }
                    let category = CategoryObject(context: context)
                    category.title = title
                    return category
                })
            case .progress(let item):
                let chapterID = ChapterIdentifier(sourceKey: item.sourceID, mangaKey: item.mangaID, chapterKey: item.chapterID)
                let history = CoreDataManager.shared.getOrCreateHistory(chapterId: chapterID, context: context)
                history.dateRead = item.dateRead
                history.progress = Int16(clamping: item.page)
                history.total = Int16(clamping: item.total)
                history.completed = item.completed
                history.scrollPosition = item.scrollPosition.map { NSNumber(value: $0) }
                if let library = CoreDataManager.shared.getLibraryManga(mangaId: mangaID, context: context) {
                    library.lastRead = max(library.lastRead ?? .distantPast, item.dateRead)
                }
            case nil:
                if parts[0] == "library" {
                    // Remove membership only; preserve downloaded files and chapter relationships.
                    if let library = CoreDataManager.shared.getLibraryManga(mangaId: mangaID, context: context) {
                        context.delete(library)
                    }
                } else {
                    let chapterID = ChapterIdentifier(sourceKey: parts[1], mangaKey: parts[2], chapterKey: parts[3])
                    if let history = CoreDataManager.shared.getHistory(chapterId: chapterID, context: context) {
                        // Preserve reading sessions attached to the history object.
                        history.completed = false
                        history.progress = -1
                        history.total = 0
                        history.scrollPosition = nil
                        history.dateRead = .distantPast
                    }
                }
            }
        }
        if context.hasChanges { try context.save() }
        return applied
    }
}
