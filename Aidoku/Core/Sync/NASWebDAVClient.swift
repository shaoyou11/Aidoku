import Foundation
import Darwin

struct NASConnection: Codable, Equatable {
    var folder = ""
    var username = ""
    var password = ""
    var fallbackFolder: String? = nil
    var allowIPv6HTTP: Bool? = false

    func folderURL() throws -> URL {
        guard let url = URL(string: folder.trimmingCharacters(in: .whitespacesAndNewlines)),
              let host = url.host,
              url.scheme?.lowercased() == "https"
                || (url.scheme?.lowercased() == "http" && (Self.isPrivateIPv4(host) || (allowIPv6HTTP == true && Self.isIPv6(host)))),
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else {
            throw NASSyncError.invalidAddress
        }
        return url.appendingPathComponent("", isDirectory: true)
    }
    func fallbackURL() throws -> URL {
        guard let fallbackFolder, !fallbackFolder.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw NASSyncError.invalidAddress }
        var alternate = self
        alternate.folder = fallbackFolder
        return try alternate.folderURL()
    }
    static func encodedHref(_ href: String) -> String {
        // Some WebDAV servers return raw Chinese names alongside escaped spaces.
        // Preserve valid escapes while escaping non-ASCII characters once.
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~:/?#[]@!$&'()*+,;=%")
        return href.addingPercentEncoding(withAllowedCharacters: allowed) ?? href
    }
    static func isIPv6(_ host: String) -> Bool {
        let host = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        var address = in6_addr()
        return host.withCString { inet_pton(AF_INET6, $0, &address) } == 1
    }
    static func sameOrigin(_ lhs: URL, _ rhs: URL) -> Bool {
        func port(_ url: URL) -> Int { url.port ?? (url.scheme?.lowercased() == "https" ? 443 : 80) }
        return lhs.scheme?.lowercased() == rhs.scheme?.lowercased()
            && lhs.host?.lowercased() == rhs.host?.lowercased() && port(lhs) == port(rhs)
    }
    static func message(for error: Error) -> String {
        if let error = error as? NASSyncError { return error.localizedDescription }
        if let error = error as? NASComicError { return error.localizedDescription }
        switch (error as? URLError)?.code {
        case .cancelled: return "操作已取消，可以重试。"
        case .timedOut: return "连接超时，请检查 NAS 是否在线及 IPv6 网络是否可达。"
        case .notConnectedToInternet, .networkConnectionLost: return "网络已断开，请联网后重试。"
        case .cannotFindHost, .dnsLookupFailed: return "无法解析服务器地址，请检查域名或 IPv6 地址格式。"
        case .serverCertificateUntrusted, .serverCertificateHasBadDate, .serverCertificateHasUnknownRoot, .secureConnectionFailed:
            return "HTTPS 证书校验失败。IPv6 直连时请使用证书匹配的域名；不会忽略证书校验。"
        default: return "未能连接 NAS，请检查 WebDAV 服务、网络和访问权限。"
        }
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
    private let router: NASRequestRouter
    private let connectionMetrics: NASConnectionMetrics
    var routeLabel: String { router.routeLabel }
    static let maxBytes = 25 * 1024 * 1024

    init(connection: NASConnection, configuration: URLSessionConfiguration = .ephemeral) {
        self.connection = connection
        self.router = NASRequestRouter(connection: connection)
        self.connectionMetrics = NASConnectionMetrics(connection: connection)
        super.init()
        configuration.timeoutIntervalForRequest = 12
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

    func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        connectionMetrics.collect(task: task, metrics: metrics)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        connectionMetrics.complete(task: task, error: error)
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
        let (data, response) = try await router.send(request) { request in
            let (bytes, response) = try await self.session.bytes(for: request)
            defer { bytes.task.cancel() }
            guard let response = response as? HTTPURLResponse else { throw NASSyncError.http(0) }
            try self.check(response.statusCode, allowed: [207])
            guard response.expectedContentLength <= Self.maxBytes else { throw NASSyncError.tooLarge }
            var data = Data()
            for try await byte in bytes {
                guard data.count < Self.maxBytes else { throw NASSyncError.tooLarge }
                data.append(byte)
            }
            return (data, response)
        }
        let actualFolder = response.url ?? folder
        return try NASFolderListing.decode(data, at: actualFolder).map {
            NASFolder(url: try router.logicalURL($0.url), name: $0.name)
        }
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
        let (_, response) = try await router.send(request("MKCOL", url: url)) { try await self.session.data(for: $0) }
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
        try await router.send(request("GET")) { request in
            let (bytes, response) = try await self.session.bytes(for: request)
            defer { bytes.task.cancel() }
            guard let response = response as? HTTPURLResponse else { throw NASSyncError.http(0) }
            if response.statusCode == 404 { return (NASSyncDocument(), nil as String?) }
            try self.check(response.statusCode, allowed: [200])
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
        let (_, response) = try await router.send(request) { try await self.session.data(for: $0) }
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
