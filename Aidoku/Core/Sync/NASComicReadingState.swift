import Foundation

extension NASComicManager {
    typealias ReadingState = NASComicReadingProgress
    func readingStates() async -> [String: ReadingState] {
        guard let fingerprint = try? configuration().fingerprint else { return [:] }
        var linkedPaths: [ChapterIdentifier: String] = [:]
        for (key, value) in UserDefaults.standard.dictionaryRepresentation() where key.hasPrefix("NASComics.link.") {
            guard let data = value as? Data, let link = try? JSONDecoder().decode(NASComicLink.self, from: data), link.deleted != true,
                  key == "NASComics.link." + NASComicPaths.hash(fingerprint + Self.linkPath(source: link.source, manga: link.manga, chapter: link.chapter)) else { continue }
            linkedPaths[.init(sourceKey: link.source, mangaKey: link.manga, chapterKey: link.chapter)] = link.path
        }
        let links = linkedPaths
        let sources = Array(Set(links.keys.map(\.sourceKey)).union([NASSourceRunner.sourceKey]))
        return await CoreDataManager.shared.container.performBackgroundTask { context in
            let request = HistoryObject.fetchRequest()
            request.predicate = NSPredicate(format: "sourceId IN %@", sources)
            let rows = (try? context.fetch(request)) ?? []
            var result: [String: ReadingState] = [:]
            for row in rows {
                let path: String
                if row.sourceId == NASSourceRunner.sourceKey {
                    guard let value = try? NASComicPaths.path(row.chapterId, fingerprint: fingerprint) else { continue }
                    path = value
                } else {
                    guard let value = links[row.identifier] else { continue }
                    path = value
                }
                let value = ReadingState(path: path, page: Int(row.progress), total: Int(row.total), completed: row.completed, date: row.dateRead ?? .distantPast)
                if result[path].map({ $0.date > value.date }) != true { result[path] = value }
            }
            return result
        }
    }
}
