import Foundation

let safe = MangaIdentifier(sourceKey: "mixed", mangaKey: "safe")
let adult = MangaIdentifier(sourceKey: "mixed", mangaKey: "adult")
let manual = MangaIdentifier(sourceKey: "mixed", mangaKey: "manual")
let explicitSource = MangaIdentifier(sourceKey: "adult-source", mangaKey: "unknown")
var policy = PrivacyDisplayPolicy(marked: [manual], knownExplicit: [adult], explicitSources: ["adult-source"])
precondition(policy.hidesExplicit)
var loadingPolicy = policy
loadingPolicy.knownRatingsLoaded = false
precondition(!loadingPolicy.allows(safe))
loadingPolicy.enabled = false
precondition(loadingPolicy.allows(adult))
precondition(policy.allows(safe))
precondition(!policy.allows(adult))
precondition(!policy.allows(manual))
precondition(!policy.allows(explicitSource))
precondition(!policy.allows(safe, rating: 2))
precondition(policy.allows(safe, rating: 1)) // suggestive is not mislabeled as explicit
policy.temporarilyRevealed = true
precondition([safe, adult, manual, explicitSource].allSatisfy { policy.allows($0) })
policy.temporarilyRevealed = false
precondition(!policy.allows(adult))
policy.enabled = false
precondition(policy.allows(adult, rating: 2))
let saved = try JSONEncoder().encode(policy.marked)
let restored = try JSONDecoder().decode(Set<MangaIdentifier>.self, from: saved)
precondition(restored == [manual])
var taps = LibraryTripleTap()
precondition(!taps.tap(isLibrary: true, at: 1))
precondition(!taps.tap(isLibrary: true, at: 1.2))
precondition(taps.tap(isLibrary: true, at: 1.4))
precondition(!taps.tap(isLibrary: true, at: 2))
precondition(!taps.tap(isLibrary: true, at: 3)) // long gaps reset the sequence
precondition(!taps.tap(isLibrary: false, at: 3.1))
precondition(!taps.tap(isLibrary: true, at: 3.2))
precondition(!taps.tap(isLibrary: true, at: 3.4))
precondition(taps.tap(isLibrary: true, at: 3.6))
print("PASS: default privacy, explicit/manual/source ratings, reveal/hide, disable filtering, persisted marks, continuous triple tap")
