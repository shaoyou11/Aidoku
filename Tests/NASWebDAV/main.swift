import Foundation

final class MockDAV: URLProtocol {
    static var document: NASSyncDocument?
    static var revision = 0
    static var writes = 0
    static var etagEnabled = true
    static var forceStatus: Int?
    static var corrupt = false
    static var conflictOnce = false
    static var rejectWrites = false
    static var conditionals: [String] = []
    static var requests: [URLRequest] = []

    static func reset(_ document: NASSyncDocument? = nil) {
        self.document = document
        revision = document == nil ? 0 : 1
        writes = 0
        etagEnabled = true
        forceStatus = nil
        corrupt = false
        conflictOnce = false
        rejectWrites = false
        conditionals = []
        requests = []
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        do {
            Self.requests.append(request)
            var status = Self.forceStatus ?? 200
            var data = Data()
            var headers: [String: String] = [:]
            if Self.forceStatus == nil {
                if request.httpMethod == "PROPFIND" {
                    status = 207
                    data = Data("<d:multistatus xmlns:d=\"DAV:\"><d:response><d:href>/aidoku/</d:href><d:propstat><d:prop><d:resourcetype><d:collection/></d:resourcetype></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response></d:multistatus>".utf8)
                } else if request.httpMethod == "MKCOL" {
                    status = 201
                } else if request.httpMethod == "GET" {
                    status = Self.document == nil ? 404 : 200
                    if let document = Self.document {
                        data = Self.corrupt ? Data("broken".utf8) : try JSONEncoder().encode(document)
                        if Self.etagEnabled { headers["ETag"] = "\"\(Self.revision)\"" }
                    }
                } else if request.httpMethod == "PUT" {
                    Self.writes += 1
                    if Self.conflictOnce {
                        Self.conflictOnce = false
                        let value = NASSyncValue.library(.init(sourceID: "s", mangaID: "concurrent", title: "Concurrent",
                            author: nil, cover: nil, dateAdded: Date(timeIntervalSince1970: 400), categories: []))
                        Self.document?.records[value.key] = .init(modified: Date(timeIntervalSince1970: 400), device: "B", value: value)
                        Self.revision += 1
                    }
                    let condition = request.value(forHTTPHeaderField: Self.document == nil ? "If-None-Match" : "If-Match")
                    Self.conditionals.append(condition ?? "MISSING")
                    if Self.rejectWrites || condition != (Self.document == nil ? "*" : "\"\(Self.revision)\"") {
                        status = 412
                    } else {
                        var body = request.httpBody ?? Data()
                        if let stream = request.httpBodyStream {
                            stream.open()
                            defer { stream.close() }
                            var buffer = [UInt8](repeating: 0, count: 4096)
                            while stream.hasBytesAvailable {
                                let count = stream.read(&buffer, maxLength: buffer.count)
                                if count <= 0 { break }
                                body.append(contentsOf: buffer.prefix(count))
                            }
                        }
                        Self.document = try JSONDecoder().decode(NASSyncDocument.self, from: body)
                        Self.revision += 1
                        status = 201
                    }
                }
            }
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
}

@main struct Tests {
    static func expect(_ value: Bool, _ message: String) { if !value { fatalError(message) } }
    static func main() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockDAV.self]
        let client = NASWebDAVClient(connection: .init(folder: "https://nas.invalid/aidoku", username: "test", password: "test"), configuration: configuration)
        defer { client.close() }
        let value = NASSyncValue.library(.init(sourceID: "s", mangaID: "local", title: "Local", author: nil, cover: nil,
                                             dateAdded: Date(timeIntervalSince1970: 100), categories: []))
        var local = NASSyncDocument()
        local.capture([value.key: value], device: "A", now: Date(timeIntervalSince1970: 100))
        MockDAV.reset()
        let first = try await client.synchronize(local)
        expect(first == local && MockDAV.conditionals == ["*"], "first creation must be conditional and verified")
        MockDAV.reset(local)
        _ = try await client.synchronize(local)
        expect(MockDAV.writes == 0, "unchanged sync must not write")
        MockDAV.reset(.init())
        _ = try await client.synchronize(local)
        expect(MockDAV.conditionals == ["\"1\""], "updates must use exact ETag")
        MockDAV.reset(.init())
        MockDAV.conflictOnce = true
        let merged = try await client.synchronize(local)
        expect(merged.records.count == 2 && MockDAV.writes == 2, "concurrent writes must refetch and preserve remote changes")
        MockDAV.reset(.init())
        MockDAV.rejectWrites = true
        do { _ = try await client.synchronize(local); fatalError("conflict accepted") } catch NASSyncError.conflict {}
        expect(MockDAV.writes == 3, "retry limit must be bounded")
        MockDAV.reset(local)
        MockDAV.etagEnabled = false
        do { _ = try await client.synchronize(local); fatalError("missing ETag accepted") } catch NASSyncError.unsupportedServer {}
        expect(MockDAV.writes == 0, "missing ETag must never overwrite remote")
        MockDAV.reset(local)
        MockDAV.corrupt = true
        do { _ = try await client.synchronize(local); fatalError("corrupt file accepted") } catch NASSyncError.invalidDocument {}
        expect(MockDAV.writes == 0, "corrupt data must never be overwritten")
        MockDAV.reset()
        MockDAV.forceStatus = 401
        do { _ = try await client.synchronize(local); fatalError("unauthorized accepted") } catch NASSyncError.authentication {}
        expect(MockDAV.writes == 0, "authentication failure must not write")
        do { _ = try NASConnection(folder: "http://nas.invalid/").fileURL(); fatalError("HTTP accepted") } catch NASSyncError.invalidAddress {}
        do { _ = try NASConnection(folder: "https://user:secret@nas.invalid/").fileURL(); fatalError("embedded credentials accepted") } catch NASSyncError.invalidAddress {}
        for host in ["10.0.0.1", "172.16.0.1", "172.31.255.254", "192.168.12.12"] {
            let url = try NASConnection(folder: "http://\(host):5005/aidoku").folderURL()
            expect(url.scheme == "http", "private HTTP accepted")
        }
        for host in ["172.15.0.1", "172.32.0.1", "192.169.0.1", "127.0.0.1", "169.254.1.1", "8.8.8.8", "nas.local", "[::1]"] {
            do { _ = try NASConnection(folder: "http://\(host)/").folderURL(); fatalError("non-private HTTP accepted") }
            catch NASSyncError.invalidAddress {}
        }
        MockDAV.reset()
        let lanRoot = URL(string: "http://192.168.12.12:5005/aidoku/")!
        let lanClient = NASWebDAVClient(connection: .init(folder: lanRoot.absoluteString, username: "test", password: "test"), configuration: configuration)
        defer { lanClient.close() }
        _ = try await lanClient.listFolders(at: lanRoot)
        _ = try await lanClient.createFolder(named: "同步", in: lanRoot)
        _ = try await lanClient.synchronize(local)
        expect(MockDAV.requests.allSatisfy { $0.url?.scheme == "http" && $0.url?.host == "192.168.12.12" }, "LAN HTTP browsing, creation and sync keep same origin")
        MockDAV.reset()
        let root = URL(string: "https://nas.invalid/aidoku/")!
        let folders = try await client.listFolders(at: root)
        expect(folders.isEmpty && MockDAV.requests.last?.value(forHTTPHeaderField: "Depth") == "1", "browse uses depth one PROPFIND")
        let created = try await client.createFolder(named: "漫画 同步", in: root)
        expect(created.lastPathComponent == "漫画 同步" && MockDAV.requests.last?.httpMethod == "MKCOL", "create encodes Chinese folder names")
        let count = MockDAV.requests.count
        do { _ = try await client.createFolder(named: "../escape", in: root); fatalError("traversal accepted") } catch NASSyncError.invalidFolderName {}
        do { _ = try await client.listFolders(at: URL(string: "https://foreign.invalid/")!); fatalError("foreign origin accepted") } catch NASSyncError.invalidAddress {}
        expect(MockDAV.requests.count == count, "invalid names and foreign origins must not send credentials")
        MockDAV.forceStatus = 403
        do { _ = try await client.createFolder(named: "denied", in: root); fatalError("permission failure accepted") } catch NASSyncError.authentication {}
        MockDAV.forceStatus = 405
        do { _ = try await client.createFolder(named: "existing", in: root); fatalError("existing folder accepted") } catch NASSyncError.folderExists {}
        print("PASS: 10 sync transport scenarios plus folder browsing, MKCOL, path encoding, origin and permission checks")
    }
}
