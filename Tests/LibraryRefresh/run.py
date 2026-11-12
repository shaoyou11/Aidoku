from pathlib import Path
import os, subprocess, tempfile
root = Path(__file__).resolve().parents[2]
manager = (root / 'Aidoku/Core/Library/Services/MangaManager.swift').read_text()
start = manager.index('    private nonisolated func shouldSkip(')
end = manager.index('    private func doLibraryRefresh(', start)
method = manager[start:end].replace('private nonisolated func', 'func')
notification = next(x.strip() for x in manager.splitlines() if 'let notificationsEnabled =' in x)
sound_source = (root / 'Aidoku/Core/Library/Services/NotificationManager.swift').read_text()
sound = next(x.strip().split(' = ', 1)[1] for x in sound_source.splitlines() if 'content.sound =' in x)
fixture = r'''import Foundation
struct NSManagedObjectContext {}
enum UpdateStrategy { case never, always }
enum Status { case ongoing, completed }
struct Manga {
 var updateStrategy = UpdateStrategy.always
 var nextUpdateTime: Date? = nil
 var sourceId = "loaded"
 var status = Status.ongoing
 var identifier = "book"
 var langFilter: [String] = []
 var scanlatorFilter: [String] = []
}
struct Category { var title: String? = "excluded" }
struct CoreDataManager {
 static let shared = CoreDataManager()
 func unreadCount(mangaId: String, lang: [String], scanlators: [String], context: NSManagedObjectContext) -> Int { 3 }
 func readCount(mangaId: String, lang: [String], scanlators: [String], context: NSManagedObjectContext) -> Int { 0 }
 func getCategories(mangaId: String, context: NSManagedObjectContext) -> [Category] { [Category()] }
}
struct Flag { var value: Bool; func get() -> Bool { value } }
struct LibrarySettings { var newChapterNotificationSound = Flag(value: false) }
enum AppSettings { static var library = LibrarySettings() }
struct Sound: Equatable { static let `default` = Sound() }
struct NotificationManager { static let shared = NotificationManager(); func isEnabled() -> Bool { true } }
struct Worker {
''' + method + r'''
}
func notify(isUserInitiated: Bool, isBackground: Bool) -> Bool {
''' + notification + r'''
 return notificationsEnabled
}
func soundValue() -> Sound? {
 return ''' + sound + r'''
}
let worker = Worker()
let context = NSManagedObjectContext()
var book = Manga()
book.nextUpdateTime = Date().addingTimeInterval(3600)
book.status = .completed
let skip = ["completed", "notStarted", "hasUnread"]
precondition(worker.shouldSkip(manga: book, options: skip, excludedCategories: ["excluded"], loadedSourceKeys: ["loaded"], context: context))
precondition(!worker.shouldSkip(manga: book, options: skip, forceAll: true, excludedCategories: ["excluded"], loadedSourceKeys: ["loaded"], context: context))
precondition(worker.shouldSkip(manga: book, options: [], forceAll: true, loadedSourceKeys: [], context: context))
book.updateStrategy = .never
precondition(worker.shouldSkip(manga: book, options: [], forceAll: true, loadedSourceKeys: ["loaded"], context: context))
precondition(!notify(isUserInitiated: true, isBackground: false))
precondition(!notify(isUserInitiated: true, isBackground: true))
precondition(!notify(isUserInitiated: false, isBackground: false))
precondition(notify(isUserInitiated: false, isBackground: true))
precondition(soundValue() == nil)
AppSettings.library.newChapterNotificationSound.value = true
precondition(soundValue() == .default)
print("PASS: full manual refresh bypasses automatic skips/deadlines; missing/non-updatable sources remain excluded; manual notifications suppressed in foreground/background; sound follows setting")
'''
folder = Path(tempfile.mkdtemp(prefix='aidoku-refresh-tests-'))
(folder / 'main.swift').write_text(fixture)
subprocess.run(['xcrun', 'swift', str(folder / 'main.swift')], check=True,
               env=os.environ | {'DEVELOPER_DIR': '/Applications/Xcode.app/Contents/Developer'})
ui = (root / 'Aidoku/Features/Library/LibraryViewController.swift').read_text()
ui = ui[ui.index('    @objc func updateLibraryRefresh('):ui.index('    @objc func openDownloadQueue()')]
assert ui.count('forceAll: true') == 2 and ui.count('isUserInitiated: true') == 2
assert ui.count('category: nil') == 2 and 'currentCategory' not in ui
manual = manager[manager.index('        if isUserInitiated {'):manager.index('        targetCategory = category')]
assert 'await refreshLibrary' in manual and 'return' in manual
settings = (root / 'Aidoku/Core/Settings/Library/LibrarySettings.swift').read_text()
assert 'newChapterNotificationSound = SettingsKey<Bool>("Library.newChapterNotificationSound", default: false)' in settings
print('PASS: both pull-to-refresh routes target the whole library; manual path bypasses continued-processing scheduling; notification sound defaults off')
