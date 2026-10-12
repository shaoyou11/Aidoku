import Foundation

/// File transfers use disk-backed URLSession tasks. A temporary remote name is published only after PUT succeeds.
final class NASComicClient: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    static let maxFileBytes: Int64 = 1024 * 1024 * 1024
    private let connection: NASConnection
    let root: URL
    private var session: URLSession!
    private let router: NASRequestRouter
    private let connectionMetrics: NASConnectionMetrics
    var routeLabel: String { router.routeLabel }
    private let progress: @Sendable (Int64, Int64) -> Void

    init(connection: NASConnection, root: URL, configuration: URLSessionConfiguration = .ephemeral,
         progress: @escaping @Sendable (Int64, Int64) -> Void = { _, _ in }) throws {
        guard NASConnection.sameOrigin(try connection.folderURL(), root), root.user == nil, root.password == nil,
              root.query == nil, root.fragment == nil else { throw NASSyncError.invalidAddress }
        self.connection = connection
        self.router = NASRequestRouter(connection: connection)
        self.connectionMetrics = NASConnectionMetrics(connection: connection)
        self.root = root.appendingPathComponent("", isDirectory: true)
        self.progress = progress
        super.init()
        configuration.timeoutIntervalForRequest = 12
        configuration.timeoutIntervalForResource = 3600
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }
    func close() { session.invalidateAndCancel() }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if totalBytesWritten > Self.maxFileBytes || totalBytesExpectedToWrite > Self.maxFileBytes { downloadTask.cancel() }
        progress(totalBytesWritten, totalBytesExpectedToWrite)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
                    totalBytesSent: Int64, totalBytesExpectedToSend: Int64) { progress(totalBytesSent, totalBytesExpectedToSend) }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil) // Never forward login details to a redirect target.
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        connectionMetrics.collect(task: task, metrics: metrics)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        connectionMetrics.complete(task: task, error: error)
    }

    private func request(_ method: String, path: String) throws -> URLRequest {
        var request = URLRequest(url: try NASComicPaths.url(path, root: root))
        request.httpMethod = method
        request.setValue("Basic " + Data("\(connection.username):\(connection.password)".utf8).base64EncodedString(), forHTTPHeaderField: "Authorization")
        return request
    }
    private func check(_ response: URLResponse, allowed: Set<Int>) throws {
        guard let http = response as? HTTPURLResponse else { throw NASSyncError.http(0) }
        guard !allowed.contains(http.statusCode) else { return }
        switch http.statusCode {
        case 401, 403: throw NASSyncError.authentication
        case 404, 409: throw NASSyncError.missingFolder
        case 412: throw NASComicError.exists
        default: throw NASSyncError.http(http.statusCode)
        }
    }
    func list(_ path: String, extensions: Set<String> = ["cbz", "zip"]) async throws -> [NASComicEntry] {
        let folder = try NASComicPaths.url(path, root: root).appendingPathComponent("", isDirectory: true)
        var request = try request("PROPFIND", path: path)
        request.url = folder
        request.setValue("1", forHTTPHeaderField: "Depth")
        request.setValue("application/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("<d:propfind xmlns:d=\"DAV:\"><d:prop><d:resourcetype/><d:getcontentlength/><d:getetag/></d:prop></d:propfind>".utf8)
        let (data, response) = try await router.send(request) { request in
            let (bytes, response) = try await self.session.bytes(for: request)
            defer { bytes.task.cancel() }
            try self.check(response, allowed: [207])
            guard response.expectedContentLength <= NASWebDAVClient.maxBytes else { throw NASSyncError.tooLarge }
            var data = Data()
            for try await byte in bytes {
                guard data.count < NASWebDAVClient.maxBytes else { throw NASSyncError.tooLarge }
                data.append(byte)
            }
            return (data, response)
        }
        let actualFolder = response.url ?? folder
        let actualRoot = try router.routed(URLRequest(url: root)).url ?? root
        return try NASComicDirectory.decode(data, at: actualFolder, root: actualRoot, extensions: extensions)
    }
    func ensureFolder(_ path: String) async throws {
        var request = try request("MKCOL", path: path)
        request.url = request.url?.appendingPathComponent("", isDirectory: true)
        let (_, response) = try await router.send(request) { try await self.session.data(for: $0) }
        if (response as? HTTPURLResponse)?.statusCode == 405 {
            _ = try await list(path) // A 405 alone does not prove a writable directory exists.
            return
        }
        try check(response, allowed: [201])
    }
    func upload(_ file: URL, path: String) async throws {
        let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size > 0, size <= Self.maxFileBytes else { throw NASComicError.tooLarge }
        let (_, existing) = try await router.send(request("HEAD", path: path)) { try await self.session.data(for: $0) }
        if (existing as? HTTPURLResponse)?.statusCode == 200 { throw NASComicError.exists }
        try check(existing, allowed: [404])
        let parent = (path as NSString).deletingLastPathComponent
        let temp = (parent.isEmpty ? "" : parent + "/") + ".upload-" + UUID().uuidString + ".cbz"
        var put = try request("PUT", path: temp)
        put.setValue("application/vnd.comicbook+zip", forHTTPHeaderField: "Content-Type")
        put.setValue("*", forHTTPHeaderField: "If-None-Match")
        let (_, uploaded) = try await router.send(put) { try await self.session.upload(for: $0, fromFile: file) }
        try check(uploaded, allowed: [200, 201, 204])
        try Task.checkCancellation()
        var move = try request("MOVE", path: temp)
        move.setValue(try NASComicPaths.url(path, root: root).absoluteString, forHTTPHeaderField: "Destination")
        move.setValue("F", forHTTPHeaderField: "Overwrite")
        let (_, moved) = try await router.send(move) { try await self.session.data(for: $0) }
        try check(moved, allowed: [201, 204])
        let (_, verified) = try await router.send(request("HEAD", path: path)) { try await self.session.data(for: $0) }
        try check(verified, allowed: [200])
        guard verified.expectedContentLength == size else { throw NASComicError.invalidArchive }
    }
    func readLink(_ path: String) async throws -> Data? {
        try await router.send(request("GET", path: path)) { request in
            let (bytes, response) = try await self.session.bytes(for: request)
            defer { bytes.task.cancel() }
            if (response as? HTTPURLResponse)?.statusCode == 404 { return nil as Data? }
            try self.check(response, allowed: [200])
            guard response.expectedContentLength <= 64 * 1024 else { throw NASComicError.invalidArchive }
            var data = Data()
            for try await byte in bytes {
                guard data.count < 64 * 1024 else { throw NASComicError.invalidArchive }
                data.append(byte)
            }
            return data
        }
    }
    func writeLink(_ data: Data, path: String) async throws {
        guard data.count <= 64 * 1024 else { throw NASComicError.invalidArchive }
        var request = try request("PUT", path: path)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = data
        let (_, response) = try await router.send(request) { try await self.session.data(for: $0) }
        try check(response, allowed: [200, 201, 204])
    }

    func range(_ entry: NASComicEntry, start: Int64, count: Int64) async throws -> Data {
        guard start >= 0, count > 0, count <= 64 * 1024 * 1024, start <= entry.size, count <= entry.size - start else { throw NASComicError.invalidArchive }
        var request = try request("GET", path: entry.path)
        request.setValue("bytes=\(start)-\(start + count - 1)", forHTTPHeaderField: "Range")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        if let etag = entry.etag, etag.hasPrefix("\""), etag.hasSuffix("\""), !etag.contains("\n") { request.setValue(etag, forHTTPHeaderField: "If-Match") }
        return try await router.send(request) { request in
            let (bytes, response) = try await self.session.bytes(for: request)
            defer { bytes.task.cancel() }
            guard let http = response as? HTTPURLResponse else { throw NASComicError.invalidArchive }
            if http.statusCode == 412 { throw NASComicError.invalidArchive }
            if [200, 416].contains(http.statusCode) { throw NASComicError.requiresWholeArchive }
            try self.check(response, allowed: [206])
            guard http.value(forHTTPHeaderField: "Content-Range") == "bytes \(start)-\(start + count - 1)/\(entry.size)" else { throw NASComicError.invalidArchive }
            var data = Data(); data.reserveCapacity(Int(count))
            for try await byte in bytes {
                guard data.count < count else { throw NASComicError.invalidArchive }
                data.append(byte)
            }
            guard data.count == count else { throw NASComicError.invalidArchive }
            return data
        }
    }

    func download(_ entry: NASComicEntry, to destination: URL) async throws {
        guard entry.size <= Self.maxFileBytes else { throw NASComicError.tooLarge }
        var request = try request("GET", path: entry.path)
        if let etag = entry.etag, etag.hasPrefix("\""), etag.hasSuffix("\""), !etag.contains("\n") {
            request.setValue(etag, forHTTPHeaderField: "If-Match")
        }
        let (file, response) = try await router.send(request) { try await self.session.download(for: $0) }
        defer { try? FileManager.default.removeItem(at: file) }
        try check(response, allowed: [200])
        let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size > 0, size <= Self.maxFileBytes else { throw NASComicError.tooLarge }
        guard entry.size == 0 || size == entry.size else { throw NASComicError.invalidArchive }
        try Task.checkCancellation()
        try FileManager.default.moveItem(at: file, to: destination)
    }
}
