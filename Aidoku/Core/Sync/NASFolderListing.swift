import Foundation

struct NASFolder: Identifiable, Equatable {
    let url: URL
    let name: String
    var id: String { url.absoluteString }
}

/// Only successful DAV collection properties are accepted; foreign origins are never followed.
final class NASFolderListing: NSObject, XMLParserDelegate {
    private var stack: [String] = []
    private var text = ""
    private var href = ""
    private var status = ""
    private var collection = false
    private var successfulCollection = false
    private var rows: [String] = []
    private var multistatus = false

    static func decode(_ data: Data, at base: URL) throws -> [NASFolder] {
        let delegate = NASFolderListing()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        guard parser.parse(), delegate.multistatus else { throw NASSyncError.invalidDocument }
        let basePath = base.standardized.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        var found: [String: NASFolder] = [:]
        var foundSelf = false
        for href in delegate.rows {
            guard let url = URL(string: href, relativeTo: base)?.absoluteURL.standardized,
                  url.scheme == base.scheme, url.host == base.host, url.port == base.port,
                  url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else { continue }
            let path = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            if path == basePath { foundSelf = true; continue }
            let parent = url.deletingLastPathComponent().path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard parent == basePath else { continue }
            let folder = url.appendingPathComponent("", isDirectory: true)
            found[path] = NASFolder(url: folder, name: url.lastPathComponent)
        }
        guard foundSelf else { throw NASSyncError.invalidDocument }
        return found.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
        stack.append(elementName)
        text = ""
        if elementName == "multistatus", namespaceURI == "DAV:" { multistatus = true }
        if elementName == "response" { href = ""; successfulCollection = false }
        if elementName == "propstat" { status = ""; collection = false }
        if elementName == "collection", namespaceURI == "DAV:", stack.contains("resourcetype") { collection = true }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?) {
        if elementName == "href", stack.dropLast().last == "response" { href = text.trimmingCharacters(in: .whitespacesAndNewlines) }
        if elementName == "status", stack.contains("propstat") { status = text }
        if elementName == "propstat", status.split(separator: " ").dropFirst().first == "200", collection { successfulCollection = true }
        if elementName == "response", successfulCollection { rows.append(href) }
        stack.removeLast()
        text = ""
    }
}
