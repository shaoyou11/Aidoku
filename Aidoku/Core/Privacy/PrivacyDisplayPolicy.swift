import Foundation

/// Display filtering only: it never deletes library, history, or download records.
struct PrivacyDisplayPolicy: Sendable, Equatable {
    var knownRatingsLoaded = true
    var enabled = true
    var temporarilyRevealed = false
    var marked: Set<MangaIdentifier> = []
    var knownExplicit: Set<MangaIdentifier> = []
    var explicitSources: Set<String> = []

    var hidesExplicit: Bool { enabled && !temporarilyRevealed }

    func allows(_ id: MangaIdentifier, rating: Int = -1) -> Bool {
        !hidesExplicit || (knownRatingsLoaded && rating != 2 && !marked.contains(id)
            && !knownExplicit.contains(id) && !explicitSources.contains(id.sourceKey))
    }
}

/// A continuous sequence is deliberately short; switching tabs cancels it.
struct LibraryTripleTap: Sendable {
    private var previous: TimeInterval = -.infinity
    private var count = 0

    mutating func tap(isLibrary: Bool, at time: TimeInterval) -> Bool {
        guard isLibrary else { count = 0; previous = -.infinity; return false }
        count = time - previous <= 0.45 ? count + 1 : 1
        previous = time
        if count == 3 { count = 0; return true }
        return false
    }
}
