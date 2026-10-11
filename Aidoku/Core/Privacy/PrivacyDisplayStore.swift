import AidokuRunner
import Combine
import CoreData
import SwiftUI

extension Notification.Name {
    static let privacyDisplayChanged = Notification.Name("AidokuT.privacyDisplayChanged")
}

@MainActor
final class PrivacyDisplayStore: ObservableObject {
    static let shared = PrivacyDisplayStore()
    @Published private(set) var policy: PrivacyDisplayPolicy
    private var cancellables: Set<AnyCancellable> = []
    private var taps = LibraryTripleTap()
    private var ratingsRefreshTask: Task<Void, Never>?
    private var ratingsRefreshID = UUID()

    private init() {
        let defaults = UserDefaults.standard
        let marked = defaults.data(forKey: "PrivacyDisplay.marked")
            .flatMap { try? JSONDecoder().decode(Set<MangaIdentifier>.self, from: $0) } ?? []
        policy = PrivacyDisplayPolicy(
            knownRatingsLoaded: false,
            enabled: defaults.object(forKey: "PrivacyDisplay.enabled") as? Bool ?? true,
            marked: marked
        )
        NotificationCenter.default.publisher(for: NSManagedObjectContext.didSaveObjectsNotification)
            .sink { [weak self] notification in
                // Inspect on the saving context queue; never pass managed objects between actors.
                let changedManga = [NSInsertedObjectsKey, NSUpdatedObjectsKey, NSDeletedObjectsKey].contains { key in
                    (notification.userInfo?[key] as? Set<NSManagedObject>)?.contains { $0 is MangaObject } ?? false
                }
                guard changedManga else { return }
                Task { @MainActor in self?.scheduleRatingsRefresh() }
            }.store(in: &cancellables)
        NotificationCenter.default.publisher(for: .updateSourceList)
            .sink { [weak self] _ in
                Task { @MainActor in await self?.refreshKnownRatings() }
            }.store(in: &cancellables)
        NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)
            .sink { [weak self] _ in
                Task { @MainActor in self?.hideAgain() }
            }.store(in: &cancellables)
    }

    func setEnabled(_ enabled: Bool) {
        policy.enabled = enabled
        policy.temporarilyRevealed = false
        UserDefaults.standard.set(enabled, forKey: "PrivacyDisplay.enabled")
        changed()
    }

    func libraryTabTapped(isLibrary: Bool) {
        if taps.tap(isLibrary: isLibrary, at: ProcessInfo.processInfo.systemUptime), policy.enabled {
            policy.temporarilyRevealed.toggle()
            UISelectionFeedbackGenerator().selectionChanged()
            changed()
        }
    }

    func hideAgain() {
        taps = LibraryTripleTap()
        guard policy.temporarilyRevealed else { return }
        policy.temporarilyRevealed = false
        changed()
    }

    func toggleMarked(_ id: MangaIdentifier) {
        if !policy.marked.insert(id).inserted { policy.marked.remove(id) }
        if let data = try? JSONEncoder().encode(policy.marked) {
            UserDefaults.standard.set(data, forKey: "PrivacyDisplay.marked")
        }
        changed()
    }

    private func scheduleRatingsRefresh() {
        ratingsRefreshTask?.cancel()
        ratingsRefreshTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 100_000_000) } catch { return }
            await self?.refreshKnownRatings()
        }
    }

    func refreshKnownRatings() async {
        let refreshID = UUID()
        ratingsRefreshID = refreshID
        let ids: Set<MangaIdentifier> = await CoreDataManager.shared.container.performBackgroundTask { context in
            let request = MangaObject.fetchRequest()
            request.predicate = NSPredicate(format: "nsfw == 2")
            return Set(((try? context.fetch(request)) ?? []).map(\.identifier))
        }
        let sources = await SourceManager.shared.getSourceInfos()
        guard refreshID == ratingsRefreshID, !Task.isCancelled else { return }
        var updated = policy
        updated.knownRatingsLoaded = true
        updated.knownExplicit = ids
        updated.explicitSources = Set(sources.filter { $0.contentRating == .primarilyNsfw }.map(\.sourceId))
        guard updated != policy else { return }
        policy = updated
        changed()
    }

    func allows(_ manga: AidokuRunner.Manga) -> Bool {
        policy.allows(manga.identifier, rating: manga.contentRating == .nsfw ? 2 : -1)
    }

    func allows(_ source: AidokuRunner.Source) -> Bool {
        !policy.hidesExplicit || source.contentRating != .primarilyNsfw
    }

    func filtered(_ home: Home, source: AidokuRunner.Source) -> Home {
        guard policy.hidesExplicit else { return home }
        guard allows(source) else { return Home(components: []) }
        func links(_ values: [HomeComponent.Value.Link]) -> [HomeComponent.Value.Link] {
            values.filter {
                if case .manga(let manga) = $0.value { return allows(manga) }
                // Opaque banners cannot be rated reliably; hide them in private display mode.
                return false
            }
        }
        return Home(components: home.components.compactMap { component in
            var item = component
            switch component.value {
            case let .imageScroller(values, interval, width, height):
                let values = links(values)
                guard !values.isEmpty else { return nil }
                item.value = .imageScroller(links: values, autoScrollInterval: interval, width: width, height: height)
            case let .bigScroller(values, interval):
                let values = values.filter(allows)
                guard !values.isEmpty else { return nil }
                item.value = .bigScroller(entries: values, autoScrollInterval: interval)
            case let .scroller(values, listing):
                let values = links(values)
                guard !values.isEmpty else { return nil }
                item.value = .scroller(entries: values, listing: listing)
            case let .mangaList(ranking, pageSize, values, listing):
                let values = links(values)
                guard !values.isEmpty else { return nil }
                item.value = .mangaList(ranking: ranking, pageSize: pageSize, entries: values, listing: listing)
            case let .mangaChapterList(pageSize, values, listing):
                let values = values.filter { allows($0.manga) }
                guard !values.isEmpty else { return nil }
                item.value = .mangaChapterList(pageSize: pageSize, entries: values, listing: listing)
            case .filters: break
            case let .links(values):
                let values = links(values)
                guard !values.isEmpty else { return nil }
                item.value = .links(values)
            }
            return item
        })
    }

    private func changed() {
        NotificationCenter.default.post(name: .privacyDisplayChanged, object: nil)
        NotificationCenter.default.post(name: .updateLibrary, object: nil)
    }
}
