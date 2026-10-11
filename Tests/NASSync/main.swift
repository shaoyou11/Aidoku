import Foundation

func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { fatalError(message) }
}
func progress(_ page: Int, at time: Double, chapter: String = "chapter/1") -> NASSyncValue {
    .progress(.init(sourceID: "source/1", mangaID: "book", chapterID: chapter, page: page,
                    total: 100, completed: false, dateRead: Date(timeIntervalSince1970: time), scrollPosition: 0.25))
}
func library(_ id: String) -> NASSyncValue {
    .library(.init(sourceID: "source", mangaID: id, title: id, author: nil, cover: nil,
                   dateAdded: Date(timeIntervalSince1970: 100), categories: ["收藏"]))
}
let old = progress(80, at: 100)
let new = progress(5, at: 200) // rereading must be allowed to move backwards
var a = NASSyncDocument()
a.capture([old.key: old], device: "A", now: Date(timeIntervalSince1970: 100))
var b = NASSyncDocument()
b.capture([new.key: new], device: "B", now: Date(timeIntervalSince1970: 200))
expect(a.merging(b).records[new.key]?.value == new, "latest reading wins even if page decreases")
expect(a.merging(b) == b.merging(a), "merge must converge")
expect(a.merging(a) == a, "merge must be idempotent")

let bookA = library("a"), bookB = library("b")
a.capture([old.key: old, bookA.key: bookA], device: "A", now: Date(timeIntervalSince1970: 300))
b.capture([new.key: new, bookB.key: bookB], device: "B", now: Date(timeIntervalSince1970: 300))
let union = a.merging(b)
expect(union.records.count == 3, "independent additions are retained")
var removal = union
removal.capture([new.key: new, bookB.key: bookB], device: "A", now: Date(timeIntervalSince1970: 400))
expect(removal.records[bookA.key] != nil && removal.records[bookA.key]?.value == nil, "removal creates a tombstone")
expect(removal.merging(union).records[bookA.key]?.value == nil, "old offline device must not resurrect removal")
var offline = union
let offlineRead = progress(90, at: 150)
offline.capture([offlineRead.key: offlineRead, bookA.key: bookA, bookB.key: bookB], device: "C", now: Date(timeIntervalSince1970: 900))
expect(offline.merging(union).records[new.key]?.value == new, "reconnection time must not outrank actual reading time")

var tieA = NASSyncDocument(), tieB = NASSyncDocument()
let left = progress(10, at: 500), right = progress(20, at: 500)
tieA.capture([left.key: left], device: "A", now: Date(timeIntervalSince1970: 500))
tieB.capture([right.key: right], device: "B", now: Date(timeIntervalSince1970: 500))
expect(tieA.merging(tieB) == tieB.merging(tieA), "equal timestamps converge by device identifier")
let parts = ["progress", "a/b", "c:\"d", "中文?x=1"]
let decodedParts = try NASSyncDocument.parts(NASSyncDocument.key(parts))
expect(decodedParts == parts, "identifier round trip")
let encoded = try JSONEncoder().encode(removal)
let decoded = try JSONDecoder().decode(NASSyncDocument.self, from: encoded)
expect(decoded == removal, "disk round trip preserves tombstones and positions")
try decoded.validate()
var invalid = removal
invalid.version = 2
do { try invalid.validate(); fatalError("unknown version accepted") } catch NASSyncError.invalidDocument {}
invalid = .init(records: ["not-base64": .init(modified: Date(), device: "A", value: nil)])
do { try invalid.validate(); fatalError("invalid identifier accepted") } catch NASSyncError.invalidDocument {}
invalid = .init(records: [bookA.key: .init(modified: Date(), device: "A", value: new)])
do { try invalid.validate(); fatalError("mismatched payload accepted") } catch NASSyncError.invalidDocument {}
print("PASS: 13 sync merge, deletion, offline conflict and validation checks")

let restored = removal.restoring(union)
expect(restored.records[bookA.key]?.value == bookA, "explicit restore revives live NAS entries despite local tombstones")
expect(union.restoring(removal).records[bookA.key]?.value == bookA, "restore must not apply remote deletions")
expect(a.restoring(b).records[bookA.key]?.value == bookA, "restore preserves local-only books")
expect(b.restoring(a).records[new.key]?.value == new, "restore preserves newer local reading progress")
expect(a.restoring(b).records[new.key]?.value == new, "restore imports newer NAS reading progress")
expect(restored.restoring(union) == restored, "restore is idempotent")
print("PASS: 6 read-only restore merge and preservation checks")
