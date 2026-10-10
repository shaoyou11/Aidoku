import Foundation

struct NASConnection: Codable, Equatable {
    var folder = ""
    var username = ""
    var password = ""

    func folderURL() throws -> URL {
        guard let url = URL(string: folder.trimmingCharacters(in: .whitespacesAndNewlines)),
              let host = url.host,
              url.scheme?.lowercased() == "https"
                || (url.scheme?.lowercased() == "http" && Self.isPrivateIPv4(host)),
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else {
            throw NASSyncError.invalidAddress
        }
        return url.appendingPathComponent("", isDirectory: true)
    }
    // Only literal RFC 1918 addresses may use unencrypted WebDAV.
    // Hostnames are excluded so DNS cannot move an HTTP connection onto the public Internet.
    private static func isPrivateIPv4(_ host: String) -> Bool {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }
        let octets = parts.compactMap { part -> UInt8? in
            guard part.allSatisfy({ $0 >= "0" && $0 <= "9" }),
                  let value = UInt8(part), String(value) == part else { return nil }
            return value
        }
        guard octets.count == 4 else { return false }
        return octets[0] == 10
            || (octets[0] == 172 && (16...31).contains(octets[1]))
            || (octets[0] == 192 && octets[1] == 168)
    }

    func fileURL() throws -> URL {
        try folderURL().appendingPathComponent("aidoku-sync-v1.json")
    }
}

/// Never forwards credentials through redirects, nor bypasses certificate validation.
final class NASWebDAVClient: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let connection: NASConnection
    private var session: URLSession!
    static let maxBytes = 25 * 1024 * 1024

    init(connection: NASConnection, configuration: URLSessionConfiguration = .ephemeral) {
        self.connection = connection
        super.init()
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 90
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }

    func close() { session.invalidateAndCancel() }

    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }

    private func request(_ method: String, url: URL? = nil) throws -> URLRequest {
        var request = URLRequest(url: try url ?? connection.fileURL())
        request.httpMethod = method
        let credentials = Data("\(connection.username):\(connection.password)".utf8).base64EncodedString()
        request.setValue("Basic \(credentials)", forHTTPHeaderField: "Authorization")
        return request
    }

    func listFolders(at url: URL) async throws -> [NASFolder] {
        let base = try connection.folderURL()
        guard url.scheme == base.scheme, url.host == base.host, url.port == base.port,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else {
            throw NASSyncError.invalidAddress
        }
        let folder = url.appendingPathComponent("", isDirectory: true)
        var request = try request("PROPFIND", url: folder)
        request.setValue("1", forHTTPHeaderField: "Depth")
        request.setValue("application/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("<d:propfind xmlns:d=\"DAV:\"><d:prop><d:resourcetype/></d:prop></d:propfind>".utf8)
        let (bytes, response) = try await session.bytes(for: request)
        guard let response = response as? HTTPURLResponse else { throw NASSyncError.http(0) }
        try check(response.statusCode, allowed: [207])
        var data = Data()
        for try await byte in bytes {
            guard data.count < Self.maxBytes else { throw NASSyncError.tooLarge }
            data.append(byte)
        }
        return try NASFolderListing.decode(data, at: folder)
    }

    func createFolder(named name: String, in parent: URL) async throws -> URL {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != ".", name != "..", name.utf8.count <= 255,
              !name.contains("/"), !name.contains("\\"),
              name.rangeOfCharacter(from: .controlCharacters) == nil else { throw NASSyncError.invalidFolderName }
        let base = try connection.folderURL()
        guard parent.scheme == base.scheme, parent.host == base.host, parent.port == base.port,
              parent.user == nil, parent.password == nil, parent.query == nil, parent.fragment == nil else {
            throw NASSyncError.invalidAddress
        }
        let url = parent.appendingPathComponent(name, isDirectory: true)
        let (_, response) = try await session.data(for: request("MKCOL", url: url))
        guard let response = response as? HTTPURLResponse else { throw NASSyncError.http(0) }
        if response.statusCode == 405 { throw NASSyncError.folderExists }
        try check(response.statusCode, allowed: [201])
        return url
    }

    func synchronize(_ local: NASSyncDocument) async throws -> NASSyncDocument {
        for attempt in 0..<3 {
            try Task.checkCancellation()
            let remote = try await read()
            let candidate = local.merging(remote.document)
            try candidate.validate()
            do {
                if remote.etag == nil || candidate != remote.document {
                    try await write(candidate, etag: remote.etag)
                }
                let verified = try await read()
                guard verified.etag != nil, verified.document.merging(candidate) == verified.document else {
                    throw NASSyncError.conflict
                }
                return verified.document
            } catch NASSyncError.conflict {
                if attempt == 2 { throw NASSyncError.conflict }
            }
        }
        throw NASSyncError.conflict
    }

    func read() async throws -> (document: NASSyncDocument, etag: String?) {
        let (bytes, response) = try await session.bytes(for: request("GET"))
        guard let response = response as? HTTPURLResponse else { throw NASSyncError.http(0) }
        if response.statusCode == 404 { return (.init(), nil) }
        try check(response.statusCode, allowed: [200])
        guard response.expectedContentLength <= Self.maxBytes else { throw NASSyncError.tooLarge }
        guard let etag = response.value(forHTTPHeaderField: "ETag"),
              etag.hasPrefix("\""), etag.hasSuffix("\""), !etag.contains("\n") else {
            throw NASSyncError.unsupportedServer
        }
        var data = Data()
        for try await byte in bytes {
            guard data.count < Self.maxBytes else { throw NASSyncError.tooLarge }
            data.append(byte)
        }
        guard let document = try? JSONDecoder().decode(NASSyncDocument.self, from: data) else {
            throw NASSyncError.invalidDocument
        }
        try document.validate()
        return (document, etag)
    }

    func write(_ document: NASSyncDocument, etag: String?) async throws {
        var request = try request("PUT")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(etag ?? "*", forHTTPHeaderField: etag == nil ? "If-None-Match" : "If-Match")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(document)
        guard data.count <= Self.maxBytes else { throw NASSyncError.tooLarge }
        request.httpBody = data
        let (_, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw NASSyncError.http(0) }
        try check(response.statusCode, allowed: [200, 201, 204])
    }

    private func check(_ status: Int, allowed: Set<Int>) throws {
        guard !allowed.contains(status) else { return }
        switch status {
        case 401, 403: throw NASSyncError.authentication
        case 404, 409: throw NASSyncError.missingFolder
        case 412: throw NASSyncError.conflict
        default: throw NASSyncError.http(status)
        }
    }
}
