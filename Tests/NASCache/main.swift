import Foundation
func expect(_ value: Bool, _ note: String) { if !value { fatalError(note) } }
let cap = NASComicCachePolicy.maximumBytes
for saved in [-1, 0, 1, 4096, Int.max] {
    expect(NASComicCachePolicy.limit(savedMB: saved) == cap, "invalid settings cannot bypass 2 GB")
}
for value in NASComicCachePolicy.capacitiesMB {
    expect(NASComicCachePolicy.limit(savedMB: value) <= cap, "every UI choice obeys hard limit")
}
expect(NASComicCachePolicy.fits(bytes: 1, used: cap - 1, limit: cap), "exact boundary fits")
expect(!NASComicCachePolicy.fits(bytes: 2, used: cap - 1, limit: cap), "actual oversized download rejected")
expect(!NASComicCachePolicy.fits(bytes: 1, used: cap, limit: cap), "full cache rejects new content")
expect(!NASComicCachePolicy.fits(bytes: 0, used: 0, limit: cap), "empty archive rejected")
expect(!NASComicCachePolicy.fits(bytes: Int64.max, used: cap, limit: Int64.max), "no integer overflow bypass")
expect(NASComicCachePolicy.remaining(used: cap, limit: 256 * 1024 * 1024) == 0, "lowering capacity preserves existing files and blocks additions")
expect(NASComicCachePolicy.remaining(used: 0, limit: Int64.max) == cap, "defensive hard cap")
print("PASS: cache capacity choices, 2 GB hard ceiling, actual size checks, lowered-capacity safety and overflow guards")

let reading = NASComicReadingProgress(path: "manga/one.cbz", page: 3, total: 10, completed: false, date: Date())
expect(reading.label == "第 3 / 10 页", "reader history pages are one-based; do not offset progress")
expect(NASComicReadingProgress(path: "", page: -1, total: 0, completed: false, date: Date()).label == "未读", "unset history is not progress")
expect(NASComicReadingProgress(path: "", page: 10, total: 10, completed: true, date: Date()).label == "已读完", "completed state is explicit")
print("PASS: actual reader page numbering, unset progress and completed labels")
