import Foundation

final class RangeServer: URLProtocol {
    enum Mode { case normal, ignored, unsatisfiable, wrongRange, short, excess, changed, unauthorized }
    static var mode = Mode.normal
    static var archive = Data()
    static var requests: [URLRequest] = []
    static var returnedBytes = 0
    static func reset(_ mode: Mode = .normal) { self.mode = mode; requests = []; returnedBytes = 0 }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        Self.requests.append(request)
        guard let range = request.value(forHTTPHeaderField: "Range"), range.hasPrefix("bytes="),
              request.httpMethod == "GET" else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse)); return
        }
        let parts = range.dropFirst(6).split(separator: "-")
        guard parts.count == 2, let start = Int(parts[0]), let end = Int(parts[1]),
              start >= 0, end >= start, end < Self.archive.count else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse)); return
        }
        var body = Self.archive.subdata(in: start ..< end + 1)
        var status = 206
        var contentRange = "bytes \(start)-\(end)/\(Self.archive.count)"
        switch Self.mode {
        case .normal: break
        case .ignored: status = 200; body = Self.archive
        case .unsatisfiable: status = 416; body = Data()
        case .wrongRange: contentRange = "bytes 0-1/\(Self.archive.count)"
        case .short: body.removeLast()
        case .excess: body.append(0)
        case .changed: status = 412; body = Data()
        case .unauthorized: status = 401; body = Data()
        }
        Self.returnedBytes += body.count
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Range": contentRange, "Content-Length": String(body.count)])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
}

/// Headers and the first bytes arrive successfully; the primary socket then drops.
final class MidstreamServer: URLProtocol {
    static var body = Data()
    static var status = 200
    static var headers: [String: String] = [:]
    static var hosts: [String] = []
    static func reset(body: Data, status: Int, headers: [String: String] = [:]) {
        self.body = body; self.status = status; self.headers = headers; hosts = []
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        let host = request.url!.host!
        Self.hosts.append(host)
        let response = HTTPURLResponse(url: request.url!, statusCode: Self.status, httpVersion: "HTTP/1.1", headerFields: Self.headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if host == "nas.invalid" {
            client?.urlProtocol(self, didLoad: Self.body.prefix(1))
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) {
                self.client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
            }
        } else {
            client?.urlProtocol(self, didLoad: Self.body)
            client?.urlProtocolDidFinishLoading(self)
        }
    }
}

@main struct OnlineTests {
    static func expect(_ condition: Bool, _ message: String) { if !condition { fatalError(message) } }
    static func invalid(_ action: () throws -> Void) {
        do { try action(); fatalError("invalid ZIP accepted") } catch NASComicError.invalidArchive {} catch { fatalError("wrong ZIP error: \(error)") }
    }
    static func unsupported(_ action: () throws -> Void) {
        do { try action(); fatalError("unsupported ZIP accepted") } catch NASComicError.requiresWholeArchive {} catch { fatalError("wrong unsupported error: \(error)") }
    }
    static func main() async throws {
        let fixture = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let migrationFolder = fixture.appendingPathComponent("local-chapter")
        try FileManager.default.createDirectory(at: migrationFolder, withIntermediateDirectories: true)
        for name in ["2.jpg", "10.png", "ComicInfo.xml"] {
            let bytes = name == "ComicInfo.xml" ? Data("<ComicInfo/>".utf8) : try Data(contentsOf: fixture.appendingPathComponent(name == "2.jpg" ? "page2.bin" : "page10.bin"))
            try bytes.write(to: migrationFolder.appendingPathComponent(name))
        }
        let verifiedArchive = fixture.appendingPathComponent("chapter.cbz")
        expect(try NASComicVerification.localFiles(directory: migrationFolder, archive: verifiedArchive).count == 3, "verified migration must include exactly this chapter's files")
        try Data("changed".utf8).write(to: migrationFolder.appendingPathComponent("2.jpg"))
        do { _ = try NASComicVerification.localFiles(directory: migrationFolder, archive: verifiedArchive); fatalError("changed local page accepted for deletion") } catch NASComicError.localChanged { }
        expect(FileManager.default.fileExists(atPath: migrationFolder.appendingPathComponent("10.png").path), "failed verification must preserve all original files")
        let copiedChapter = fixture.appendingPathComponent("archive-chapter")
        try FileManager.default.copyItem(at: verifiedArchive, to: copiedChapter.appendingPathExtension("cbz"))
        expect(try NASComicVerification.localFiles(directory: copiedChapter, archive: verifiedArchive).count == 1, "compressed download migration must select only one archive")
        expect(try !NASComicVerification.sameChapter(verifiedArchive, fixture.appendingPathComponent("streamed.cbz")), "same-name but different chapter must not qualify for cleanup")
        print("PASS: migration manifests, changed local download preservation, compressed chapter identity and same-name mismatch")
        let archive = try Data(contentsOf: fixture.appendingPathComponent("chapter.cbz"))
        let tailCount = min(65557, archive.count)
        let tail = archive.subdata(in: archive.count - tailCount ..< archive.count)
        let directory = try NASZIPIndex.directory(tail: tail, total: Int64(archive.count))
        let central = archive.subdata(in: Int(directory.offset) ..< Int(directory.offset + directory.count))
        let entries = try NASZIPIndex.entries(central)
        expect(entries.map(\.name) == ["2.jpg", "10.png"], "only image pages, in natural page order")
        let metadataEntries = try NASZIPIndex.entries(central, includeMetadata: true)
        let info = metadataEntries.first(where: { $0.name == "ComicInfo.xml" })!
        let infoStart = Int(info.offset)
        let infoLength = 30 + Int(NASZIPIndex.u16(archive, infoStart + 26)) + Int(NASZIPIndex.u16(archive, infoStart + 28)) + Int(info.compressedSize)
        let infoXML = try NASComicManager.decodeOnlinePage(archive.subdata(in: infoStart ..< infoStart + infoLength), entry: info)
        expect(String(data: infoXML, encoding: .utf8) == "<ComicInfo/>", "metadata must decode via ranges without becoming a reader page")
        var oversizedInfo = info.centralRecord
        oversizedInfo.replaceSubrange(24..<28, with: [0, 0, 32, 0])
        invalid { _ = try NASZIPIndex.entries(oversizedInfo, includeMetadata: true) }
        print("PASS: bounded ComicInfo metadata extraction and separation from image pages")

        expect(NASZIPIndex.u16(entries[0].centralRecord, 10) == 0 && NASZIPIndex.u16(entries[1].centralRecord, 10) == 8, "stored and deflated pages both indexed")
        for (entry, expected) in zip(entries, ["page2.bin", "page10.bin"]) {
            let offset = Int(entry.offset)
            let header = archive.subdata(in: offset ..< offset + 30)
            let length = 30 + Int(NASZIPIndex.u16(header, 26)) + Int(NASZIPIndex.u16(header, 28)) + Int(entry.compressedSize)
            let local = archive.subdata(in: offset ..< offset + length)
            let data = try NASComicManager.decodeOnlinePage(local, entry: entry)
            expect(data == (try Data(contentsOf: fixture.appendingPathComponent(expected))), "range reconstruction must decode the exact page")
            invalid { _ = try NASZIPIndex.singleArchive(local: local.dropLast(), entry: entry) }
        }
        let streamed = try Data(contentsOf: fixture.appendingPathComponent("streamed.cbz"))
        let streamedDirectory = try NASZIPIndex.directory(tail: streamed, total: Int64(streamed.count))
        let streamedCentral = streamed.subdata(in: Int(streamedDirectory.offset) ..< Int(streamedDirectory.offset + streamedDirectory.count))
        let streamedPage = try NASZIPIndex.entries(streamedCentral)[0]
        expect(NASZIPIndex.u16(streamedPage.centralRecord, 8) & 8 != 0, "fixture uses streaming data descriptor")
        let streamedLength = 30 + Int(NASZIPIndex.u16(streamed, 26)) + Int(NASZIPIndex.u16(streamed, 28)) + Int(streamedPage.compressedSize)
        let streamedLocal = streamed.subdata(in: 0 ..< streamedLength)
        let streamedImage = try NASComicManager.decodeOnlinePage(streamedLocal, entry: streamedPage)
        expect(streamedImage == (try Data(contentsOf: fixture.appendingPathComponent("page10.bin"))), "streamed ZIP descriptor must decode correctly")
        let stored = entries[0]
        let offset = Int(stored.offset)
        let length = 30 + Int(NASZIPIndex.u16(archive, offset + 26)) + Int(NASZIPIndex.u16(archive, offset + 28)) + Int(stored.compressedSize)
        var corrupt = archive.subdata(in: offset ..< offset + length)
        corrupt[corrupt.count - 1] ^= 1
        do { _ = try NASComicManager.decodeOnlinePage(corrupt, entry: stored); fatalError("corrupt page CRC accepted") } catch {}
        invalid { _ = try NASZIPIndex.directory(tail: Data([1, 2, 3]), total: 3) }
        unsupported { _ = try NASZIPIndex.entries(central.dropLast()) }
        var encrypted = entries[0].centralRecord; encrypted[8] |= 1
        unsupported { _ = try NASZIPIndex.entries(encrypted) }
        var method = entries[0].centralRecord; method[10] = 99
        unsupported { _ = try NASZIPIndex.entries(method) }
        var zip64 = entries[0].centralRecord; zip64.replaceSubrange(20..<24, with: [255, 255, 255, 255])
        unsupported { _ = try NASZIPIndex.entries(zip64) }
        var traversal = entries[0].centralRecord; traversal.replaceSubrange(46..<51, with: Array("../x/".utf8))
        invalid { _ = try NASZIPIndex.entries(traversal) }
        var giant = entries[0].centralRecord; giant.replaceSubrange(24..<28, with: [1, 0, 0, 4])
        invalid { _ = try NASZIPIndex.entries(giant) }
        var multidisk = tail
        let endOffset = multidisk.count - 22 - Int(NASZIPIndex.u16(archive, Int(directory.offset + directory.count) + 20))
        multidisk[endOffset + 4] = 1
        unsupported { _ = try NASZIPIndex.directory(tail: multidisk, total: Int64(archive.count)) }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RangeServer.self]
        let connection = NASConnection(folder: "https://nas.invalid/comics/", username: "fixture", password: "fixture")
        let client = try NASComicClient(connection: connection, root: connection.folderURL(), configuration: configuration)
        defer { client.close() }
        let entry = NASComicEntry(name: "chapter.cbz", path: "chapter.cbz", isDirectory: false, size: Int64(archive.count), etag: "\"fixture-v1\"")
        RangeServer.archive = archive
        RangeServer.reset()
        let rangeTail = try await client.range(entry, start: entry.size - Int64(tailCount), count: Int64(tailCount))
        let rangeDirectory = try NASZIPIndex.directory(tail: rangeTail, total: entry.size)
        let rangeCentral = try await client.range(entry, start: rangeDirectory.offset, count: rangeDirectory.count)
        let page = try NASZIPIndex.entries(rangeCentral)[1]
        let header = try await client.range(entry, start: page.offset, count: 30)
        let pageLength = 30 + Int64(NASZIPIndex.u16(header, 26)) + Int64(NASZIPIndex.u16(header, 28)) + page.compressedSize
        let compressedPage = try await client.range(entry, start: page.offset, count: pageLength)
        let image = try NASComicManager.decodeOnlinePage(compressedPage, entry: page)
        expect(image == (try Data(contentsOf: fixture.appendingPathComponent("page10.bin"))), "online page content")
        expect(RangeServer.requests.count == 4 && RangeServer.returnedBytes < archive.count / 2, "opening one page must not download the whole chapter")
        expect(RangeServer.requests.allSatisfy { $0.value(forHTTPHeaderField: "If-Match") == "\"fixture-v1\"" && $0.value(forHTTPHeaderField: "Accept-Encoding") == "identity" }, "ranges must pin exact archive version and avoid transfer compression")
        for mode in [RangeServer.Mode.ignored, .unsatisfiable] {
            RangeServer.reset(mode)
            do { _ = try await client.range(entry, start: 0, count: 30); fatalError("unsupported Range accepted") }
            catch NASComicError.requiresWholeArchive {}
            expect(RangeServer.requests.count == 1, "unsupported Range must not silently retry a whole-file GET")
        }
        for mode in [RangeServer.Mode.wrongRange, .short, .excess, .changed] {
            RangeServer.reset(mode)
            do { _ = try await client.range(entry, start: 0, count: 30); fatalError("invalid range accepted") }
            catch NASComicError.invalidArchive {}
        }
        RangeServer.reset(.unauthorized)
        do { _ = try await client.range(entry, start: 0, count: 30); fatalError("unauthorized range accepted") }
        catch NASSyncError.authentication {}
        RangeServer.reset()
        for (start, count) in [(Int64(-1), Int64(10)), (Int64(0), Int64(0)), (entry.size - 1, Int64(2))] {
            do { _ = try await client.range(entry, start: start, count: count); fatalError("out-of-bounds request sent") }
            catch NASComicError.invalidArchive {}
        }
        expect(RangeServer.requests.isEmpty, "invalid ranges must fail before touching network")
        let failoverConfiguration = URLSessionConfiguration.ephemeral
        failoverConfiguration.protocolClasses = [MidstreamServer.self]
        let failoverConnection = NASConnection(folder: "https://nas.invalid/comics/", username: "fixture", password: "fixture", fallbackFolder: "https://backup.invalid/comics/")
        let root = try failoverConnection.folderURL()
        let document = NASSyncDocument()
        MidstreamServer.reset(body: try JSONEncoder().encode(document), status: 200, headers: ["ETag": "\"v1\""])
        let syncClient = NASWebDAVClient(connection: failoverConnection, configuration: failoverConfiguration)
        let read = try await syncClient.read()
        syncClient.close()
        expect(read.document == document && MidstreamServer.hosts == ["nas.invalid", "backup.invalid"], "sync body disconnect must retry fallback")
        let xml = Data("<d:multistatus xmlns:d=\"DAV:\"><d:response><d:href>/comics/</d:href><d:propstat><d:prop><d:resourcetype><d:collection/></d:resourcetype></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response><d:response><d:href>/comics/folder/</d:href><d:propstat><d:prop><d:resourcetype><d:collection/></d:resourcetype></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response></d:multistatus>".utf8)
        MidstreamServer.reset(body: xml, status: 207)
        let folderClient = NASWebDAVClient(connection: failoverConnection, configuration: failoverConfiguration)
        let folders = try await folderClient.listFolders(at: root)
        folderClient.close()
        expect(folders.count == 1 && folders[0].url.host == "nas.invalid" && MidstreamServer.hosts == ["nas.invalid", "backup.invalid"], "folder body disconnect must retry and retain logical primary identity")
        MidstreamServer.reset(body: xml, status: 207)
        let comicListClient = try NASComicClient(connection: failoverConnection, root: root, configuration: failoverConfiguration)
        let comicFolders = try await comicListClient.list("")
        comicListClient.close()
        expect(comicFolders.count == 1 && MidstreamServer.hosts == ["nas.invalid", "backup.invalid"], "comic listing body disconnect must retry fallback")
        let linkData = Data("{\"chapter\":\"fixture\"}".utf8)
        MidstreamServer.reset(body: linkData, status: 200)
        let linkClient = try NASComicClient(connection: failoverConnection, root: root, configuration: failoverConfiguration)
        let link = try await linkClient.readLink(".aidokut-links/fixture.json")
        linkClient.close()
        expect(link == linkData && MidstreamServer.hosts == ["nas.invalid", "backup.invalid"], "association body disconnect must retry fallback")
        MidstreamServer.reset(body: archive.prefix(30), status: 206, headers: ["Content-Range": "bytes 0-29/\(entry.size)"])
        let rangeClient = try NASComicClient(connection: failoverConnection, root: root, configuration: failoverConfiguration)
        let headerAfterDrop = try await rangeClient.range(entry, start: 0, count: 30)
        rangeClient.close()
        expect(headerAfterDrop == archive.prefix(30) && MidstreamServer.hosts == ["nas.invalid", "backup.invalid"], "page body disconnect must restart exact range on fallback without mixing bytes")
        print("PASS: all five streaming reads retry secondary after headers and partial primary body")
        print("PASS: online ZIP stored/deflate/CRC, natural ordering, malformed/encrypted/ZIP64 bounds, partial-range reading, no silent whole-file fallback, server errors and conditional version guards")
    }
}
