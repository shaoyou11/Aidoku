import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(Combine)
import Combine
#endif

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


/// A completed network request, never a cached read or a guess based on endpoint labels.
struct NASConnectionSnapshot: Equatable, Sendable {
    let address: String
    let remoteAddress: String?
    let family: String
    let route: String
    let connectedAt: Date

    init?(url: URL, remoteAddress: String?, route: String, connectedAt: Date = Date()) {
        guard var origin = URLComponents(url: url, resolvingAgainstBaseURL: false),
              ["http", "https"].contains(origin.scheme?.lowercased() ?? ""), origin.host != nil else { return nil }
        origin.user = nil; origin.password = nil; origin.path = ""; origin.query = nil; origin.fragment = nil
        guard let address = origin.url?.absoluteString else { return nil }
        self.address = address
        let literal = remoteAddress?.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if let literal, NASConnection.isIPv6(literal) {
            self.remoteAddress = literal
            self.family = literal.lowercased().hasPrefix("::ffff:") && literal.contains(".") ? "IPv4" : "IPv6"
        } else if let literal, Self.isIPv4(literal) {
            self.remoteAddress = literal
            self.family = "IPv4"
        } else {
            self.remoteAddress = nil
            self.family = "未知"
        }
        self.route = route
        self.connectedAt = connectedAt
    }

    private static func isIPv4(_ value: String) -> Bool {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 4 && parts.allSatisfy { part in
            guard let number = UInt8(part) else { return false }
            return String(number) == part
        }
    }
}

#if canImport(Combine)
@MainActor
final class NASConnectionStatus: ObservableObject {
    static let shared = NASConnectionStatus()
    @Published private(set) var snapshot: NASConnectionSnapshot?
    @Published private(set) var lastFailureAt: Date?

    func reset() {
        NASConnectionGeneration.shared.advance()
        snapshot = nil
        lastFailureAt = nil
    }

    func record(_ snapshot: NASConnectionSnapshot) {
        guard self.snapshot.map({ $0.connectedAt <= snapshot.connectedAt }) ?? true else { return }
        self.snapshot = snapshot
    }
    func failed(at date: Date) {
        guard lastFailureAt.map({ $0 <= date }) ?? true else { return }
        lastFailureAt = date
    }
}
#endif

/// Invalidates observations from old in-flight clients after the user saves a different connection.
private final class NASConnectionGeneration: @unchecked Sendable {
    static let shared = NASConnectionGeneration()
    private let lock = NSLock()
    private var generation: UInt64 = 0
    var current: UInt64 { lock.lock(); defer { lock.unlock() }; return generation }
    func advance() { lock.lock(); generation &+= 1; lock.unlock() }
}

/// Joins metrics with completion: receiving headers alone must not report a failed transfer as connected.
/// URLSession delegate callbacks may arrive on different queues, so per-task metrics are protected by a lock.
final class NASConnectionMetrics: @unchecked Sendable {
    private struct Transfer {
        let url: URL
        let remoteAddress: String?
        let status: Int
    }
    private let connection: NASConnection
    private let generation = NASConnectionGeneration.shared.current
    private let lock = NSLock()
    private var transfers: [Int: Transfer] = [:]

    init(connection: NASConnection) { self.connection = connection }

    func collect(task: URLSessionTask, metrics: URLSessionTaskMetrics) {
        if let transaction = metrics.transactionMetrics.last,
           transaction.resourceFetchType == .networkLoad,
           let response = transaction.response as? HTTPURLResponse,
           let url = response.url {
            #if os(Linux)
            let remoteAddress: String? = nil
            #else
            let remoteAddress = transaction.remoteAddress
            #endif
            lock.lock()
            transfers[task.taskIdentifier] = Transfer(url: url, remoteAddress: remoteAddress, status: response.statusCode)
            lock.unlock()
        }
        // Async URLSession convenience methods do not forward didCompleteWithError to this delegate.
        // At collection completion Foundation exposes the final task error and completed state.
        if task.state == .completed { complete(task: task, error: task.error) }
    }

    func complete(task: URLSessionTask, error: Error?) {
        lock.lock()
        let transfer = transfers.removeValue(forKey: task.taskIdentifier)
        lock.unlock()
        // Closing a view/byte stream is not a failed NAS connection.
        if (error as? URLError)?.code == .cancelled { return }
        guard error == nil, let transfer, (200..<300).contains(transfer.status) else {
            if error != nil || transfer.map({ !(200..<300).contains($0.status) }) == true { failed() }
            return
        }
        guard let snapshot = Self.successfulSnapshot(url: transfer.url, remoteAddress: transfer.remoteAddress,
                                                     status: transfer.status, error: error, connection: connection) else { return }
        #if canImport(Combine)
        Task { @MainActor [generation] in
            guard generation == NASConnectionGeneration.shared.current else { return }
            NASConnectionStatus.shared.record(snapshot)
        }
        #endif
    }

    static func successfulSnapshot(url: URL, remoteAddress: String?, status: Int, error: Error?,
                                   connection: NASConnection, networkLoad: Bool = true) -> NASConnectionSnapshot? {
        guard networkLoad, error == nil, (200..<300).contains(status),
              let primary = try? connection.folderURL() else { return nil }
        let fallback = (try? connection.fallbackURL()).map { NASConnection.sameOrigin($0, url) } ?? false
        guard fallback || NASConnection.sameOrigin(primary, url) else { return nil }
        return NASConnectionSnapshot(url: url, remoteAddress: remoteAddress, route: fallback ? "备用地址" : "优先地址")
    }

    private func failed() {
        let date = Date()
        #if canImport(Combine)
        Task { @MainActor [generation] in
            guard generation == NASConnectionGeneration.shared.current else { return }
            NASConnectionStatus.shared.failed(at: date)
        }
        #endif
    }
}
