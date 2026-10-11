import Foundation

/// Retries only connectivity failures using the second endpoint explicitly configured by the user.
/// It never follows arbitrary server redirects, nor retries authentication or content errors.
final class NASRequestRouter: @unchecked Sendable {
    private let connection: NASConnection
    private let lock = NSLock()
    private var fallback = false
    init(connection: NASConnection) { self.connection = connection }
    private var usingFallback: Bool { lock.lock(); defer { lock.unlock() }; return fallback }
    private func selectFallback() { lock.lock(); fallback = true; lock.unlock() }

    static func canFailOver(_ error: Error) -> Bool {
        guard !Task.isCancelled, let error = error as? URLError else { return false }
        return [.timedOut, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed, .networkConnectionLost,
                .notConnectedToInternet, .secureConnectionFailed, .serverCertificateUntrusted,
                .serverCertificateHasBadDate, .serverCertificateHasUnknownRoot].contains(error.code)
    }
    func send<T>(_ original: URLRequest, operation: (URLRequest) async throws -> T) async throws -> T {
        do { return try await operation(try routed(original)) }
        catch {
            guard !usingFallback, Self.canFailOver(error), let secondary = connection.fallbackFolder,
                  !secondary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw error }
            _ = try connection.fallbackURL()
            selectFallback()
            return try await operation(try routed(original))
        }
    }
    var routeLabel: String { usingFallback ? "备用地址" : "优先地址" }

    func routed(_ original: URLRequest) throws -> URLRequest {
        guard usingFallback else { return original }
        let primary = try connection.folderURL()
        let secondary = try connection.fallbackURL()
        func mapped(_ url: URL) throws -> URL {
            guard NASConnection.sameOrigin(url, primary) else { throw NASSyncError.invalidAddress }
            var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
            let replacement = URLComponents(url: secondary, resolvingAgainstBaseURL: false)!
            components.scheme = replacement.scheme
            components.host = replacement.host
            components.port = replacement.port
            let basePath = primary.path.hasSuffix("/") ? primary.path : primary.path + "/"
            if url.path.hasPrefix(basePath) {
                components.path = secondary.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                components.path = (components.path.isEmpty ? "/" : "/" + components.path + "/") + String(url.path.dropFirst(basePath.count))
            } else if url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) == primary.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) {
                components.path = secondary.path
            }
            guard let mapped = components.url else { throw NASSyncError.invalidAddress }
            return mapped
        }
        var result = original
        if let url = original.url { result.url = try mapped(url) }
        if let destination = original.value(forHTTPHeaderField: "Destination"), let url = URL(string: destination) {
            result.setValue(try mapped(url).absoluteString, forHTTPHeaderField: "Destination")
        }
        return result
    }

    /// DAV hrefs must be interpreted against the actual responding origin, then mapped back to logical primary URLs.
    func logicalURL(_ actual: URL) throws -> URL {
        guard usingFallback else { return actual }
        let primary = try connection.folderURL()
        let secondary = try connection.fallbackURL()
        guard NASConnection.sameOrigin(actual, secondary) else { throw NASSyncError.invalidAddress }
        var components = URLComponents(url: actual, resolvingAgainstBaseURL: false)!
        let replacement = URLComponents(url: primary, resolvingAgainstBaseURL: false)!
        components.scheme = replacement.scheme; components.host = replacement.host; components.port = replacement.port
        let base = secondary.path.hasSuffix("/") ? secondary.path : secondary.path + "/"
        if actual.path.hasPrefix(base) {
            components.path = primary.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            components.path = (components.path.isEmpty ? "/" : "/" + components.path + "/") + String(actual.path.dropFirst(base.count))
        } else if actual.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) == secondary.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) {
            components.path = primary.path
        }
        guard let url = components.url else { throw NASSyncError.invalidAddress }
        return url
    }
}
