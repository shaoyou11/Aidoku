import Foundation
import CryptoKit

struct NASComicEntry: Identifiable, Codable, Hashable, Sendable {
    let name: String
    let path: String
    let isDirectory: Bool
    let size: Int64
    let etag: String?
    var id: String { path }
}

struct NASComicUploadSummary: Codable, Sendable {
    enum State: String, Codable, Sendable { case uploading, completed, cancelled, failed }
    let sourceID: String
    let mangaID: String
    let title: String
    let folder: String
    let fingerprint: String
    let total: Int
    var uploaded = 0
    var skipped = 0
    var linked = 0
    var removedLocal: Int? = nil
    var state = State.uploading
    var error: String?
    var updatedAt = Date()
}

enum NASComicError: LocalizedError {
    case verificationFailed, localChanged, invalidArchive, tooLarge, cacheFull, wrongConnection, exists, busy, requiresWholeArchive
    var errorDescription: String? {
        switch self {
        case .verificationFailed: "NAS 文件或阅读关联校验未通过，手机原下载已保留。"
        case .localChanged: "手机章节在上传期间发生变化，原下载已保留，请重新上传。"
        case .requiresWholeArchive: "此 NAS 或压缩格式暂不支持按页在线读取。可选择“缓存整章”后阅读，不会自动下载整章。"
        case .invalidArchive: "不是可阅读的 CBZ / ZIP 漫画，或文件损坏。"
        case .tooLarge: "单章文件超过 1 GB，请拆分后再试。"
        case .cacheFull: "本章超过可用缓存容量，请在“手机章节缓存”中调整容量或选择清理后重试（最高 2 GB）。"
        case .wrongConnection: "此漫画属于另一处 NAS 漫画目录，请切回原来的连接和漫画文件夹。"
        case .exists: "NAS 已有同名章节，本次跳过，不覆盖原文件。"
        case .busy: "另一个漫画传输正在进行，请等待完成或先取消。"
        }
    }
}

/// Stable keys contain no server URL or login information. Paths must stay below the selected root.
enum NASComicPaths {
    static func hash(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    static func fingerprint(_ connection: NASConnection, root: URL) -> String {
        hash(root.absoluteString + "\n" + connection.username)
    }
    static func key(_ path: String, fingerprint: String) -> String { fingerprint + ":" + path }
    static func path(_ key: String, fingerprint: String) throws -> String {
        guard key.hasPrefix(fingerprint + ":") else { throw NASComicError.wrongConnection }
        return String(key.dropFirst(fingerprint.count + 1))
    }
    static func url(_ path: String, root: URL) throws -> URL {
        guard !path.hasPrefix("/"), !path.contains("\\"), !path.contains("\0") else { throw NASSyncError.invalidAddress }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard path.isEmpty || parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw NASSyncError.invalidAddress
        }
        return path.isEmpty ? root : parts.reduce(root) { $0.appendingPathComponent(String($1)) }
    }
    static func filename(_ title: String, identity: String) -> String {
        let clean = title.unicodeScalars.map { CharacterSet.controlCharacters.contains($0) || "/\\:".unicodeScalars.contains($0) ? "_" : String($0) }.joined()
        return String(clean.prefix(48)).trimmingCharacters(in: .whitespacesAndNewlines) + "-" + hash(identity).prefix(12)
    }
}

/// Parses only immediate DAV children, not arbitrary hrefs returned by a server.
final class NASComicDirectory: NSObject, XMLParserDelegate {
    private struct Row { var href = ""; var directory = false; var size: Int64 = 0; var etag: String? }
    private var rows: [Row] = []
    private var row = Row()
    private var properties = Row()
    private var stack: [String] = []
    private var text = ""
    private var status = ""
    private var successful = false
    private var multistatus = false

    static func decode(_ data: Data, at folder: URL, root: URL, extensions: Set<String> = ["cbz", "zip"]) throws -> [NASComicEntry] {
        let delegate = NASComicDirectory()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        guard parser.parse(), delegate.multistatus else { throw NASSyncError.invalidDocument }
        let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
        let folderPath = folder.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        var entries: [String: NASComicEntry] = [:]
        var foundSelf = false
        for row in delegate.rows {
            guard let url = URL(string: NASConnection.encodedHref(row.href), relativeTo: folder)?.absoluteURL.standardized,
                  NASConnection.sameOrigin(url, root), url.user == nil, url.password == nil,
                  url.query == nil, url.fragment == nil else { continue }
            if url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) == folderPath {
                foundSelf = row.directory; continue
            }
            guard url.path.hasPrefix(rootPath),
                  url.deletingLastPathComponent().path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) == folderPath,
                  !url.lastPathComponent.hasPrefix("."),
                  row.directory || extensions.contains(url.pathExtension.lowercased()) else { continue }
            let path = String(url.path.dropFirst(rootPath.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard (try? NASComicPaths.url(path, root: root)) != nil else { continue }
            entries[path] = .init(name: url.lastPathComponent, path: path, isDirectory: row.directory, size: row.size, etag: row.etag)
        }
        guard foundSelf else { throw NASSyncError.invalidDocument }
        return entries.values.sorted {
            if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }
    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
        stack.append(name); text = ""
        if name == "multistatus", namespaceURI == "DAV:" { multistatus = true }
        if name == "response" { row = Row(); successful = false }
        if name == "propstat" { properties = Row(); status = "" }
        if name == "collection", namespaceURI == "DAV:" { properties.directory = true }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }
    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        if name == "href", stack.dropLast().last == "response" { row.href = text.trimmingCharacters(in: .whitespacesAndNewlines) }
        if name == "status", stack.contains("propstat") { status = text }
        if name == "getcontentlength" { properties.size = max(0, Int64(text.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0) }
        if name == "getetag" { properties.etag = text.trimmingCharacters(in: .whitespacesAndNewlines) }
        if name == "propstat", status.split(separator: " ").dropFirst().first == "200" {
            row.directory = row.directory || properties.directory
            row.size = max(row.size, properties.size)
            row.etag = properties.etag ?? row.etag
            successful = true
        }
        if name == "response", successful { rows.append(row) }
        stack.removeLast(); text = ""
    }
}
