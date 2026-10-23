import Foundation

struct NASComicReadingProgress: Sendable {
    let path: String
    let page: Int
    let total: Int
    let completed: Bool
    let date: Date
    var label: String {
        if completed { return "已读完" }
        if page <= 0 { return "未读" }
        return total > 0 ? "第 \(min(page, total)) / \(total) 页" : "读到第 \(page) 页"
    }
}
