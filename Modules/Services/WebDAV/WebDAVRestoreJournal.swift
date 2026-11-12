import CryptoKit
import Darwin
import Foundation

/// 只协调固定本地文件，不持有业务状态。active标记存在表示尚未提交，启动时恢复精确原字节。
actor WebDAVRestoreJournal {
    enum Role: String, Codable, CaseIterable, Sendable {
        case bookSources, bookshelf, replaceRules
        case rssSources, rssFolders, rssArticles, rssStatuses, rssMetadata, rssVariables

        static let rssFiles: [(Role, String)] = [
            (.rssSources, "rss_sources.json"), (.rssFolders, "rss_folders.json"),
            (.rssArticles, "rss_articles.json"), (.rssStatuses, "rss_article_status.json"),
            (.rssMetadata, "rss_feed_metadata.json"), (.rssVariables, "rss_runtime_variables.json")
        ]
    }
    enum Failure: Error { case invalidJournal, activeTransaction, invalidTarget, corruptOriginal }
    struct Token: Sendable { fileprivate let id: UUID }
    private struct Entry: Codable {
        let role: Role
        let size: Int64?
        let digest: String?
    }
    private struct Record: Codable {
        let format: Int
        let id: UUID
        let entries: [Entry]
    }

    private nonisolated static let ioQueue = DispatchQueue(label: "com.yuedu.webdav.restore-journal", qos: .utility)
    private var ioInFlight = false

    static var defaultDirectory: URL {
        FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("webdav-restore-backups", isDirectory: true)
    }
    static let shared = WebDAVRestoreJournal(directory: defaultDirectory)
    let directory: URL

    init(directory: URL) { self.directory = directory }

    /// 副本、hash与manifest写入在专用utility队列，避免阻塞MainActor及并发执行器。
    func begin(targets: [Role: URL]) async throws -> Token {
        guard !ioInFlight else { throw Failure.activeTransaction }
        ioInFlight = true
        defer { ioInFlight = false }
        try Task.checkCancellation()
        let directory = self.directory
        return try await Self.performIO {
            try Self.beginTransaction(directory: directory, targets: targets)
        }
    }

    func commit(_ token: Token) async throws {
        guard !ioInFlight else { throw Failure.activeTransaction }
        ioInFlight = true
        defer { ioInFlight = false }
        try Task.checkCancellation()
        let directory = self.directory
        try await Self.performIO { try Self.commitTransaction(directory: directory, token: token) }
    }

    /// 回滚不服从取消；即使原任务已取消，专用IO队列仍完成补偿或保留active标记。
    @discardableResult
    func recover(targets: [Role: URL], token: Token? = nil) async throws -> Bool {
        guard !ioInFlight else { throw Failure.activeTransaction }
        ioInFlight = true
        defer { ioInFlight = false }
        let directory = self.directory
        return try await Self.performIO {
            try Self.recoverTransaction(directory: directory, targets: targets, token: token)
        }
    }

    private nonisolated static func performIO<Value: Sendable>(
        _ operation: @escaping @Sendable () throws -> Value
    ) async throws -> Value {
        try await withCheckedThrowingContinuation { continuation in
            ioQueue.async {
                do { continuation.resume(returning: try operation()) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }

    private nonisolated static func activeFile(in directory: URL) -> URL {
        directory.appendingPathComponent("active.json")
    }

    private nonisolated static func beginTransaction(directory: URL, targets: [Role: URL]) throws -> Token {
        guard !targets.isEmpty, Set(targets.values.map({ $0.standardizedFileURL })).count == targets.count else {
            throw Failure.invalidTarget
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try requireDirectory(directory)
        let active = activeFile(in: directory)
        guard try !regularFileExists(active) else { throw Failure.activeTransaction }
        let id = UUID()
        let backup = directory.appendingPathComponent(id.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: false)
        var entries: [Entry] = []
        for role in Role.allCases {
            guard let target = targets[role] else { continue }
            if try regularFileExists(target) {
                let saved = original(role, in: backup)
                try FileManager.default.copyItem(at: target, to: saved)
                let fingerprint = try fingerprint(saved)
                entries.append(Entry(role: role, size: fingerprint.size, digest: fingerprint.digest))
            } else {
                entries.append(Entry(role: role, size: nil, digest: nil))
            }
        }
        let data = try JSONEncoder().encode(Record(format: 1, id: id, entries: entries))
        try data.write(to: backup.appendingPathComponent("journal.json"), options: .atomic)
        // 所有原文件副本完成后才发布意图；调用方拿到token后才可替换目标。
        try data.write(to: active, options: .atomic)
        return Token(id: id)
    }

    private nonisolated static func commitTransaction(directory: URL, token: Token) throws {
        let active = activeFile(in: directory)
        guard try readRecord(active: active).id == token.id else { throw Failure.invalidJournal }
        try FileManager.default.removeItem(at: active)
    }

    private nonisolated static func recoverTransaction(
        directory: URL, targets: [Role: URL], token: Token?
    ) throws -> Bool {
        let active = activeFile(in: directory)
        guard try regularFileExists(active) else { return false }
        try requireDirectory(directory)
        let record = try readRecord(active: active)
        if let token, token.id != record.id { throw Failure.invalidJournal }
        let backup = directory.appendingPathComponent(record.id.uuidString, isDirectory: true)
        try requireDirectory(backup)
        // 校验全部副本与目标白名单，之后才动第一个目标，日志不保存远端或绝对目标路径。
        for entry in record.entries {
            guard let target = targets[entry.role] else { throw Failure.invalidTarget }
            _ = try regularFileExists(target)
            if let size = entry.size, let digest = entry.digest {
                let saved = original(entry.role, in: backup)
                guard try regularFileExists(saved) else { throw Failure.corruptOriginal }
                let actual = try fingerprint(saved)
                guard actual.size == size, actual.digest == digest else { throw Failure.corruptOriginal }
            }
        }
        for entry in record.entries.reversed() {
            guard let target = targets[entry.role] else { throw Failure.invalidTarget }
            if entry.size != nil {
                try replace(target, with: original(entry.role, in: backup))
            } else if try regularFileExists(target) {
                try FileManager.default.removeItem(at: target)
            }
        }
        // 最后清除意图；之前发生进程终止时，重启可从同一副本幂等重试。
        try FileManager.default.removeItem(at: active)
        return true
    }

    private nonisolated static func original(_ role: Role, in backup: URL) -> URL {
        backup.appendingPathComponent(role.rawValue + ".original")
    }

    private nonisolated static func readRecord(active: URL) throws -> Record {
        guard try regularFileExists(active),
              let size = try FileManager.default.attributesOfItem(atPath: active.path)[.size] as? NSNumber,
              size.int64Value <= 65_536 else { throw Failure.invalidJournal }
        let record = try JSONDecoder().decode(Record.self, from: Data(contentsOf: active))
        guard record.format == 1, !record.entries.isEmpty, record.entries.count <= Role.allCases.count,
              Set(record.entries.map(\.role)).count == record.entries.count,
              record.entries.allSatisfy({ entry in
                  guard let size = entry.size else { return entry.digest == nil }
                  return size >= 0 && entry.digest?.count == 64 && entry.digest?.allSatisfy(\.isHexDigit) == true
              }) else { throw Failure.invalidJournal }
        return record
    }

    private nonisolated static func regularFileExists(_ url: URL) throws -> Bool {
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular else { throw Failure.invalidTarget }
            return true
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile { return false }
    }

    private nonisolated static func requireDirectory(_ url: URL) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeDirectory else { throw Failure.invalidTarget }
    }

    private nonisolated static func fingerprint(_ file: URL) throws -> (size: Int64, digest: String) {
        let handle = try FileHandle(forReadingFrom: file)
        var count: Int64 = 0
        var hash = SHA256()
        do {
            while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
                count += Int64(data.count)
                hash.update(data: data)
            }
        } catch {
            try handle.close()
            throw error
        }
        try handle.close()
        return (count, hash.finalize().map { String(format: "%02x", $0) }.joined())
    }

    private nonisolated static func replace(_ target: URL, with saved: URL) throws {
        let temp = target.deletingLastPathComponent().appendingPathComponent(".webdav-recovery-" + UUID().uuidString)
        try FileManager.default.copyItem(at: saved, to: temp)
        guard Darwin.rename(temp.path, target.path) == 0 else {
            let error = NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            try FileManager.default.removeItem(at: temp)
            throw error
        }
    }
}
