import Foundation

/// Limits cover retained chapter archives and their in-flight download, never evict offline reading silently.
enum NASComicCachePolicy {
    static let maximumBytes: Int64 = 2 * 1024 * 1024 * 1024
    static let capacitiesMB = [256, 512, 1024, 2048]
    static func limit(savedMB: Int) -> Int64 {
        Int64(capacitiesMB.contains(savedMB) ? savedMB : 2048) * 1024 * 1024
    }
    static func remaining(used: Int64, limit: Int64) -> Int64 {
        max(0, min(maximumBytes, max(0, limit)) - max(0, used))
    }
    static func fits(bytes: Int64, used: Int64, limit: Int64) -> Bool {
        bytes > 0 && bytes <= remaining(used: used, limit: limit)
    }
}
