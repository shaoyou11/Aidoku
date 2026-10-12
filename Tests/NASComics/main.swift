import Foundation

@main struct Tests {
    static func expect(_ condition: Bool, _ text: String) { if !condition { fatalError(text) } }
    static func main() async throws {
        let connection = NASConnection(folder: "https://[2001:db8::1]/dav/漫画/", username: "test", password: "test", fallbackFolder: "https://fallback.invalid/dav/漫画/")
        let root = try connection.folderURL()
        expect(NASConnection.isIPv6(root.host!), "IPv6 bracket parsing")
        let old = try JSONDecoder().decode(NASConnection.self, from: Data("{\"folder\":\"https://nas.invalid/dav/\",\"username\":\"test\",\"password\":\"test\"}".utf8))
        expect(old.fallbackFolder == nil && old.allowIPv6HTTP == nil, "old saved connections remain readable")
        var direct = connection; direct.folder = "http://[2001:db8::1]:5005/dav/"; direct.allowIPv6HTTP = false
        do { _ = try direct.folderURL(); fatalError("unapproved plaintext allowed") } catch NASSyncError.invalidAddress {}
        direct.allowIPv6HTTP = true; _ = try direct.folderURL()
        for path in ["../bad", "/absolute", "folder/../bad", "folder//bad", "a\\b"] {
            do { _ = try NASComicPaths.url(path, root: root); fatalError("path escaped") } catch NASSyncError.invalidAddress {}
        }
        let chinese = try NASComicPaths.url("系列/第 2 话 #.cbz", root: root)
        expect(chinese.lastPathComponent == "第 2 话 #.cbz", "names must be encoded once")
        let router = NASRequestRouter(connection: connection)
        var request = URLRequest(url: chinese); request.httpMethod = "GET"
        var attempts = 0
        let resolved: URL = try await router.send(request) { candidate in
            attempts += 1
            if attempts == 1 { throw URLError(.cannotConnectToHost) }
            return candidate.url!
        }
        expect(attempts == 2 && resolved.host == "fallback.invalid" && resolved.path == chinese.path, "IPv6 failure must use configured fallback")
        expect(try router.logicalURL(resolved).path == chinese.path, "fallback DAV links must retain primary logical identity")
        let later = try await router.send(request) { $0.url! }
        expect(later.host == "fallback.invalid", "transaction should remain on selected endpoint")
        let single = NASRequestRouter(connection: old)
        attempts = 0
        do { let _: Int = try await single.send(URLRequest(url: try old.folderURL())) { _ in attempts += 1; throw URLError(.timedOut) }; fatalError("expected failure") }
        catch { expect(attempts == 1, "one address means one attempt") }
        let auth = NASRequestRouter(connection: connection)
        attempts = 0
        do { let _: Int = try await auth.send(request) { _ in attempts += 1; throw NASSyncError.authentication }; fatalError("expected failure") }
        catch { expect(attempts == 1, "authentication errors must not be masked by failover") }
        expect(!NASRequestRouter.canFailOver(URLError(.cancelled)), "cancelled view request is not a connection failure")
        let domainConnection = NASConnection(folder: "https://ipv6-labelled.invalid/dav/", fallbackFolder: "https://secondary.invalid:8443/backup/")
        let observed = NASConnectionMetrics.successfulSnapshot(url: URL(string: "https://ipv6-labelled.invalid/dav/chapter.cbz")!,
            remoteAddress: "192.0.2.10", status: 206, error: nil, connection: domainConnection)
        expect(observed?.family == "IPv4" && observed?.route == "优先地址", "family must follow socket metrics rather than endpoint label")
        let fallbackObservation = NASConnectionMetrics.successfulSnapshot(url: URL(string: "https://secondary.invalid:8443/backup/chapter.cbz")!,
            remoteAddress: "2001:db8::2", status: 207, error: nil, connection: domainConnection)
        expect(fallbackObservation?.family == "IPv6" && fallbackObservation?.route == "备用地址", "fallback may itself be IPv6; report actual successful endpoint")
        expect(fallbackObservation?.address == "https://secondary.invalid:8443", "only origin is shown, without comic paths")
        let sanitized = NASConnectionSnapshot(url: URL(string: "https://user:secret@nas.invalid/private?token=secret#private")!, remoteAddress: "not-an-IP", route: "优先地址")
        expect(sanitized?.address == "https://nas.invalid" && sanitized?.family == "未知" && sanitized?.remoteAddress == nil, "strip credentials and never guess missing socket metrics")
        for status in [401, 403, 500] {
            expect(NASConnectionMetrics.successfulSnapshot(url: try domainConnection.folderURL(), remoteAddress: "192.0.2.10", status: status, error: nil, connection: domainConnection) == nil, "HTTP failures must not publish success")
        }
        expect(NASConnectionMetrics.successfulSnapshot(url: try domainConnection.folderURL(), remoteAddress: "192.0.2.10", status: 200, error: URLError(.networkConnectionLost), connection: domainConnection) == nil, "received headers followed by broken transfer must not publish success")
        expect(NASConnectionMetrics.successfulSnapshot(url: try domainConnection.folderURL(), remoteAddress: "192.0.2.10", status: 200, error: nil, connection: domainConnection, networkLoad: false) == nil, "cache reads must not claim a new NAS connection")
        expect(NASConnectionMetrics.successfulSnapshot(url: URL(string: "https://foreign.invalid/")!, remoteAddress: "192.0.2.10", status: 200, error: nil, connection: domainConnection) == nil, "foreign-origin response must never identify the configured NAS")
        let xml = """
        <d:multistatus xmlns:d="DAV:">
        <d:response><d:href>/dav/漫画/</d:href><d:propstat><d:prop><d:resourcetype><d:collection/></d:resourcetype></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>
        <d:response><d:href>/dav/漫画/第%202话.cbz</d:href><d:propstat><d:prop><d:resourcetype/><d:getcontentlength>123</d:getcontentlength><d:getetag>"a"</d:getetag></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>
        <d:response><d:href>/dav/漫画/第%2010话.cbz</d:href><d:propstat><d:prop><d:resourcetype/><d:getcontentlength>456</d:getcontentlength></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>
        <d:response><d:href>https://foreign.invalid/stolen.cbz</d:href><d:propstat><d:prop/><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>
        <d:response><d:href>/dav/漫画/.upload-hidden.cbz</d:href><d:propstat><d:prop/><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>
        <d:response><d:href>/dav/漫画/secret.cbz</d:href><d:propstat><d:prop/><d:status>HTTP/1.1 403 Forbidden</d:status></d:propstat></d:response>
        </d:multistatus>
        """
        let entries = try NASComicDirectory.decode(Data(xml.utf8), at: root, root: root)
        expect(entries.count == 2 && entries[0].name == "第 2话.cbz" && entries[0].size == 123, "natural order, permissions and staging isolation")
        expect(NASComicPaths.filename("同名", identity: "one") != NASComicPaths.filename("同名", identity: "two"), "same titles must not collide")
        let fingerprint = NASComicPaths.fingerprint(connection, root: root)
        let key = NASComicPaths.key("series/chapter.cbz", fingerprint: fingerprint)
        expect(!key.contains("test") && !key.contains("db8"), "reader identity must not contain credentials or server address")
        do { _ = try NASComicPaths.path(key, fingerprint: "another"); fatalError("cross NAS identity accepted") } catch NASComicError.wrongConnection {}
        print("PASS: NAS comics paths, DAV parsing, IPv6, fallback, cancellation, observed IP family, redaction, failed/cache isolation, legacy settings and stable identity")
    }
}
