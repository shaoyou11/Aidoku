import Foundation

/// A versioned, per-item document. Tombstones prevent offline devices from resurrecting removals.
struct NASSyncDocument: Codable, Equatable {
    var version = 1
    var records: [String: NASSyncRecord] = [:]

    mutating func capture(_ snapshot: [String: NASSyncValue], device: String, now: Date) {
        for (key, value) in snapshot where records[key]?.value != value {
            let date: Date
            switch value {
            case .progress(let progress):
                // Reading time, not reconnection time, resolves offline reading conflicts.
                date = min(progress.dateRead, now)
            case .library:
                date = records[key] == nil ? min(value.initialDate, now) : now
            }
            records[key] = NASSyncRecord(modified: date, device: device, value: value)
        }
        for key in Array(records.keys) where snapshot[key] == nil && records[key]?.value != nil {
            records[key] = NASSyncRecord(modified: now, device: device, value: nil)
        }
    }

    func merging(_ other: Self) -> Self {
        var result = self
        for (key, incoming) in other.records {
            if let current = result.records[key], !incoming.isNewer(than: current) { continue }
            result.records[key] = incoming
        }
        return result
    }

    func validate() throws {
        guard version == 1, records.count <= 100_000 else { throw NASSyncError.invalidDocument }
        for (key, record) in records {
            let parts = try Self.parts(key)
            guard !record.device.isEmpty, record.modified.timeIntervalSince1970.isFinite,
                  record.modified <= Date().addingTimeInterval(300),
                  parts.count == (parts.first == "library" ? 3 : 4),
                  parts.first == "library" || parts.first == "progress",
                  parts.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 8192 }) else {
                throw NASSyncError.invalidDocument
            }
            if let value = record.value {
                guard value.key == key else { throw NASSyncError.invalidDocument }
                if case .progress(let progress) = value {
                    guard (-1...32767).contains(progress.page), (0...32767).contains(progress.total),
                          progress.dateRead.timeIntervalSince1970.isFinite,
                          progress.scrollPosition?.isFinite ?? true else { throw NASSyncError.invalidDocument }
                }
            }
        }
    }

    static func key(_ parts: [String]) -> String {
        // Array encoding makes identifiers containing separators unambiguous.
        (try? JSONEncoder().encode(parts).base64EncodedString()) ?? ""
    }

    static func parts(_ key: String) throws -> [String] {
        guard let data = Data(base64Encoded: key),
              let result = try? JSONDecoder().decode([String].self, from: data) else {
            throw NASSyncError.invalidDocument
        }
        return result
    }
}

struct NASSyncRecord: Codable, Equatable {
    let modified: Date
    let device: String
    let value: NASSyncValue?

    func isNewer(than other: Self) -> Bool {
        modified == other.modified ? device > other.device : modified > other.modified
    }
}

enum NASSyncValue: Codable, Equatable {
    case library(NASLibraryEntry)
    case progress(NASProgressEntry)

    var key: String {
        switch self {
        case .library(let item): NASSyncDocument.key(["library", item.sourceID, item.mangaID])
        case .progress(let item): NASSyncDocument.key(["progress", item.sourceID, item.mangaID, item.chapterID])
        }
    }

    var initialDate: Date {
        switch self {
        case .library(let item): item.dateAdded
        case .progress(let item): item.dateRead
        }
    }
}

struct NASLibraryEntry: Codable, Equatable {
    let sourceID: String
    let mangaID: String
    let title: String
    let author: String?
    let cover: String?
    let dateAdded: Date
    let categories: [String]
}

struct NASProgressEntry: Codable, Equatable {
    let sourceID: String
    let mangaID: String
    let chapterID: String
    let page: Int
    let total: Int
    let completed: Bool
    let dateRead: Date
    let scrollPosition: Double?
}

enum NASSyncError: LocalizedError {
    case invalidFolderName, folderExists
    case invalidAddress, invalidDocument, authentication, missingFolder, conflict, unsupportedServer, tooLarge, http(Int), keychain, localStorage

    var errorDescription: String? {
        switch self {
        case .invalidFolderName: "文件夹名称不能为空，也不能包含斜杠或使用相对路径。"
        case .folderExists: "文件夹已存在，请从列表中选择，或使用其他名称。"
        case .invalidAddress: "请输入 HTTPS WebDAV 地址，或使用局域网 IPv4 地址的 HTTP WebDAV。地址中不要包含账号或密码。"
        case .invalidDocument: "同步文件无法识别或内容异常，未覆盖数据。请检查 NAS 上的同步文件和设备时间。"
        case .authentication: "认证失败或没有访问权限，请检查账号、密码和文件夹权限。"
        case .missingFolder: "同步文件夹不存在，请先在 NAS 中创建该文件夹。"
        case .conflict: "另一台设备正在更新数据，请稍后再次同步。"
        case .unsupportedServer: "服务器未提供可靠的文件版本标记，已停止同步以避免覆盖数据。"
        case .tooLarge: "同步文件超过 25 MB，已停止同步。"
        case .http(let code): "NAS 返回错误（\(code)），请检查 WebDAV 服务。"
        case .keychain: "无法保存或读取登录信息，请解锁设备后重试。"
        case .localStorage: "无法读取或保存本机同步记录，已停止同步。"
        }
    }
}
