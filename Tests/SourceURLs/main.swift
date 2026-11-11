import Foundation

enum SourceContentRating: Int, Codable { case safe, suggestive, nsfw }
struct SourceInfo {
    let sourceId: String
    let iconUrl: URL?
    let name: String
    let altNames: [String]
    let languages: [String]
    let version: Int
    let contentRating: SourceContentRating
    let externalInfo: ExternalSourceInfo
}

@main struct SourceURLTests {
    static func source(base: URL, download: String? = nil, icon: String? = nil) throws -> ExternalSourceInfo {
        var fields: [String: Any] = ["id": "fixture", "name": "Fixture", "version": 1, "file": "fixture.aix", "icon": "fixture.png"]
        fields["downloadURL"] = download
        fields["iconURL"] = icon
        let data = try JSONSerialization.data(withJSONObject: fields)
        return try JSONDecoder().decode(ExternalSourceInfo.self, from: data).with(sourceUrl: normalizeLegacyBase(base))
    }
    static func main() throws {
        let base = "https://example.invalid/catalog/main"
        for suffix in ["", "/"] {
            let item = try source(base: URL(string: base + suffix)!)
            precondition(item.fileURL?.absoluteURL.absoluteString == base + "/sources/fixture.aix")
            precondition(item.toInfo().iconUrl?.absoluteURL.absoluteString == base + "/icons/fixture.png")
        }
        let json = try source(base: URL(string: "https://example.invalid/catalog/list.json")!)
        precondition(json.fileURL?.absoluteURL.absoluteString == "https://example.invalid/catalog/sources/fixture.aix")
        precondition(json.toInfo().iconUrl?.absoluteURL.absoluteString == "https://example.invalid/catalog/icons/fixture.png")
        let absolute = try source(base: URL(string: base)!, download: "https://cdn.invalid/package.aix", icon: "https://cdn.invalid/icon.png")
        precondition(absolute.fileURL?.absoluteURL.absoluteString == "https://cdn.invalid/package.aix")
        precondition(absolute.toInfo().iconUrl?.absoluteURL.absoluteString == "https://cdn.invalid/icon.png")
        let local = try source(base: URL(string: base)!, download: "file:///tmp/fixture.aix")
        precondition(local.fileURL?.absoluteURL == URL(fileURLWithPath: "/tmp/fixture.aix"))
        print("PASS: actual source URL/icon resolution for directory bases with/without slash, JSON bases, absolute downloads/icons and file URLs")
    }
}
