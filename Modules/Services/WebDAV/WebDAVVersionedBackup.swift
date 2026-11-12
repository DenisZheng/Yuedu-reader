import CryptoKit
import Foundation
import UIKit

/// Fork 自己的分类、版本化 WebDAV 备份（对齐 Legado 按日期保存多份备份、恢复时选择历史版本）。
///
/// 远端布局：`/readerfork-dev/backups/<yyyyMMdd'T'HHmmss'Z'-设备8位-随机6位>/{分类}.json` + `manifest.json`。
/// manifest 最后上传，是该版本完整的提交标记；没有可解析 manifest 的目录不列出、不能恢复，
/// 所以上传中断只会留下不可见的残缺目录，不会被当成可用备份。
/// 不写原版 `/yuedu/` 路径，不迁移原版数据（ADR 0002）。
enum WebDAVBackupCategory: String, CaseIterable, Codable, Identifiable, Sendable {
    case bookSources, bookshelf, replaceRules, rss
    var id: String { rawValue }
    var fileName: String { rawValue + ".json" }
    var restoreRole: WebDAVRestoreJournal.Role? {
        switch self {
        case .bookSources: .bookSources
        case .bookshelf: .bookshelf
        case .replaceRules: .replaceRules
        case .rss: nil
        }
    }
    var titleKey: String {
        switch self {
        case .bookSources: "書源"
        case .bookshelf: "書架"
        case .replaceRules: "替換規則"
        case .rss: "RSS 訂閱"
        }
    }
}

struct WebDAVBackupManifest: Codable, Equatable, Sendable {
    struct Entry: Codable, Equatable, Sendable {
        var category: WebDAVBackupCategory
        var size: Int
        var sha256: String
    }
    static let currentFormat = 1
    var format: Int
    var name: String
    var created: Date
    var deviceName: String
    var appVersion: String
    var files: [Entry]
}

enum WebDAVBackupError: LocalizedError, Equatable {
    case nothingSelected, nothingToBackUp, invalidName, unsupportedFormat, corrupt(WebDAVBackupCategory?), tooLarge, insufficientSpace, rollbackFailed
    var errorDescription: String? {
        switch self {
        case .nothingSelected: localized("請至少選擇一個備份分類")
        case .nothingToBackUp: localized("所選分類在本機沒有資料")
        case .invalidName: localized("備份名稱無效")
        case .unsupportedFormat: localized("此備份由較新版本建立，無法還原")
        case .corrupt(let category):
            category.map { String(format: localized("備份檔案已損壞：%@"), localized($0.titleKey)) } ?? localized("備份清單已損壞")
        case .tooLarge: localized("備份檔案過大")
        case .insufficientSpace: localized("裝置空間不足，未修改任何資料")
        case .rollbackFailed: localized("還原失敗，原始資料副本已保留，請勿繼續同步")
        }
    }
}

enum WebDAVBackupLayout {
    static let root = "/readerfork-dev/backups/"
    static let maximumFileBytes = 64 * 1_024 * 1_024

    static func name(date: Date, deviceID: String, nonce: String = UUID().uuidString) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        let device = deviceID.lowercased().filter { $0.isHexDigit }.prefix(8)
        let unique = nonce.lowercased().filter(\.isHexDigit).prefix(6)
        let suffix = unique.count == 6 ? String(unique) : "000000"
        return formatter.string(from: date) + "-" + String(device.count == 8 ? String(device) : "00000000") + "-" + suffix
    }

    /// 只接受自己生成的名字：防止服务器列表或篡改的manifest把路径带出备份目录。
    static func isValid(_ name: String) -> Bool {
        name.range(of: #"^\d{8}T\d{6}Z-[0-9a-f]{8}-[0-9a-f]{6}$"#, options: .regularExpression) != nil
    }

    static func directory(_ name: String) throws -> String {
        guard isValid(name) else { throw WebDAVBackupError.invalidName }
        return root + name + "/"
    }

    /// PROPFIND Depth:1 的 multistatus；畸形XML不能伪装成合法空列表，不解析外部实体。
    static func names(fromListing xml: Data) throws -> [String] {
        let parser = XMLParser(data: xml)
        let collector = Listing()
        parser.shouldProcessNamespaces = true
        parser.shouldResolveExternalEntities = false
        parser.externalEntityResolvingPolicy = .never
        parser.delegate = collector
        guard parser.parse(), collector.isMultistatus else { throw WebDAVBackupError.corrupt(nil) }
        return Array(Set(collector.names)).sorted(by: >)
    }

    private final class Listing: NSObject, XMLParserDelegate {
        var names: [String] = []
        var isMultistatus = false
        private var depth = 0
        private var hrefDepth: Int?
        private var href = ""
        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
            depth += 1
            if depth == 1 { isMultistatus = name == "multistatus" && namespaceURI == "DAV:" }
            if name == "href", namespaceURI == "DAV:" { hrefDepth = depth; href = "" }
            if depth > 32 { parser.abortParsing() }
        }
        func parser(_ parser: XMLParser, foundCharacters string: String) {
            guard hrefDepth != nil else { return }
            href += string
            if href.utf8.count > 4096 { parser.abortParsing() }
        }
        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            defer { depth -= 1 }
            guard hrefDepth == depth else { return }
            hrefDepth = nil
            guard let path = URL(string: href.trimmingCharacters(in: .whitespacesAndNewlines))?.path,
                  let last = path.split(separator: "/").last.map(String.init), isValid(last) else { return }
            names.append(last)
        }
    }

    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func decodeManifest(_ data: Data, expectedName: String) throws -> WebDAVBackupManifest {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let manifest: WebDAVBackupManifest
        do { manifest = try decoder.decode(WebDAVBackupManifest.self, from: data) }
        catch { throw WebDAVBackupError.corrupt(nil) }
        guard manifest.format <= WebDAVBackupManifest.currentFormat else { throw WebDAVBackupError.unsupportedFormat }
        guard manifest.format >= 1, manifest.name == expectedName, isValid(expectedName),
              !manifest.files.isEmpty, manifest.files.count <= WebDAVBackupCategory.allCases.count,
              manifest.deviceName.utf8.count <= 1024, manifest.appVersion.utf8.count <= 128,
              Set(manifest.files.map(\.category)).count == manifest.files.count,
              manifest.files.allSatisfy({ $0.size >= 0 && $0.size <= maximumFileBytes && $0.sha256.count == 64 && $0.sha256.allSatisfy(\.isHexDigit) })
        else { throw WebDAVBackupError.corrupt(nil) }
        return manifest
    }

    static func encodeManifest(_ manifest: WebDAVBackupManifest) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(manifest)
    }
}

/// 本机数据读写的接缝：生产实现直接读写各 store；测试注入隔离实现，不碰真实书库。
protocol WebDAVBackupLocalData: Sendable {
    /// 本机没有该分类数据时返回 nil。
    func export(_ category: WebDAVBackupCategory) async throws -> Data?
    /// 只校验，不修改本机。
    func validate(_ category: WebDAVBackupCategory, _ data: Data) async throws
    /// 全部写入；任何一步失败都要回滚已写入的分类再抛出。
    func apply(_ staged: [(WebDAVBackupCategory, Data)]) async throws
    func availableBytes() throws -> Int64
}

struct WebDAVProductionLocalData: WebDAVBackupLocalData {
    let rss: RSSStore
    let bookStore: BookStore?
    /// 测试用：把文件分类指向隔离目录，并跳过对全局 store 的重载。生产为空。
    var fileOverrides: [WebDAVBackupCategory: URL] = [:]
    var recoveryDirectory: URL = WebDAVRestoreJournal.defaultDirectory
    #if DEBUG
    /// 测试暂停在真实分类写入之后；生产恢复顺序和文件内容不变。
    var afterCategoryWrite: (@Sendable (WebDAVBackupCategory) async throws -> Void)?
    /// 验证owner发布前失败时，整个文件事务仍回滚且不清除active journal。
    var beforeStoreReload: (@Sendable () async throws -> Void)?
    #endif

    private static var replaceRulesFile: URL {
        FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0].appendingPathComponent("replace_rules.json")
    }
    private func file(_ category: WebDAVBackupCategory) -> URL? {
        if let url = fileOverrides[category] { return url }
        switch category {
        case .bookSources: return StorageLocations.bookSourcesFile
        case .bookshelf: return StorageLocations.booksMetadataFile
        case .replaceRules: return Self.replaceRulesFile
        case .rss: return nil
        }
    }

    func export(_ category: WebDAVBackupCategory) async throws -> Data? {
        if category == .bookSources, fileOverrides.isEmpty {
            let sources = await MainActor.run { BookSourceStore.shared }
            await sources.waitUntilLoaded()
            await sources.queuedWritesLanded()
        }
        switch category {
        case .rss:
            return try await rss.backupData()
        case .bookshelf:
            await BookStore.queuedWritesLanded()
            guard let url = file(category), FileManager.default.fileExists(atPath: url.path) else { return nil }
            return try WebDAVManager.bookshelfBackupData(from: Data(contentsOf: url))
        case .bookSources, .replaceRules:
            guard let url = file(category), FileManager.default.fileExists(atPath: url.path) else { return nil }
            return try Data(contentsOf: url)
        }
    }

    func validate(_ category: WebDAVBackupCategory, _ data: Data) async throws {
        do {
            switch category {
            case .bookSources: _ = try JSONDecoder().decode([BookSource].self, from: data)
            case .bookshelf:
                let books = try JSONDecoder().decode([ReadingBook].self, from: data)
                guard Set(books.map(\.id)).count == books.count else { throw WebDAVBackupError.corrupt(category) }
            case .replaceRules: _ = try JSONDecoder().decode([ReplaceRule].self, from: data)
            case .rss: _ = try await RSSBackupCodec.decode(data)
            }
        } catch { throw WebDAVBackupError.corrupt(category) }
    }

    private struct PendingRestore {
        let journal: WebDAVRestoreJournal
        let token: WebDAVRestoreJournal.Token
        let targets: [WebDAVRestoreJournal.Role: URL]
        let restoresRSS: Bool
    }

    func apply(_ staged: [(WebDAVBackupCategory, Data)]) async throws {
        if staged.contains(where: { $0.0 == .rss }) {
            try await rss.withRestoreTransaction { previous, transaction in
                let pending = try await apply(staged, previousRSS: previous, transaction: transaction)
                try await finish(pending, staged: staged, previousRSS: previous)
            }
        } else {
            let pending = try await apply(staged, previousRSS: nil, transaction: nil)
            try await finish(pending, staged: staged, previousRSS: nil)
        }
    }

    private func finish(_ pending: PendingRestore, staged: [(WebDAVBackupCategory, Data)],
                        previousRSS: RSSStore.RestoreState?) async throws {
        do {
            #if DEBUG
            try await beforeStoreReload?()
            #endif
            try await reload(staged)
            try await pending.journal.commit(pending.token)
        } catch {
            let originalError = error
            var rollbackFailed = false
            if pending.restoresRSS, let previousRSS {
                do { try await rss.restoreLocalState(previousRSS) }
                catch {
                    rollbackFailed = true
                    AppLogger.sync("WebDAV RSS owner rollback failed; local copies retained", level: .fault)
                }
            }
            do { try await pending.journal.recover(targets: pending.targets, token: pending.token) }
            catch {
                rollbackFailed = true
                AppLogger.sync("WebDAV file rollback failed; journal retained", level: .fault)
            }
            if rollbackFailed { throw WebDAVBackupError.rollbackFailed }
            throw originalError
        }
    }

    private func apply(_ staged: [(WebDAVBackupCategory, Data)], previousRSS: RSSStore.RestoreState?,
                       transaction: UUID?) async throws -> PendingRestore {
        let started = SourcePerfTrace.now
        let onMain = { Thread.isMainThread }()
        defer {
            SourcePerfTrace.record("webdav.restore.apply", "main=\(onMain) categories=\(staged.count) bytes=\(staged.reduce(0) { $0 + $1.1.count })",
                since: started, mainThreadStallBreadcrumb: false)
        }
        guard !staged.isEmpty, Set(staged.map(\.0)).count == staged.count else { throw WebDAVBackupError.corrupt(nil) }
        for (category, data) in staged { try await validate(category, data) }
        if fileOverrides.isEmpty {
            await BookStore.queuedWritesLanded()
            if staged.contains(where: { $0.0 == .bookSources }) {
                let sources = await MainActor.run { BookSourceStore.shared }
                await sources.waitUntilLoaded()
                await sources.queuedWritesLanded()
            }
        }
        let files = staged.filter { $0.0 != .rss }
        let rssData = staged.first { $0.0 == .rss }?.1
        var targets: [WebDAVRestoreJournal.Role: URL] = [:]
        for (category, _) in files {
            guard let role = category.restoreRole, let url = file(category) else { throw WebDAVBackupError.corrupt(category) }
            targets[role] = url
        }
        if rssData != nil { targets.merge(await rss.restoreFileTargets) { _, new in new } }
        let oldBytes = try targets.values.reduce(Int64(0)) { bytes, url in
            guard FileManager.default.fileExists(atPath: url.path) else { return bytes }
            return bytes + ((try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0)
        }
        let newBytes = staged.reduce(Int64(0)) { $0 + Int64($1.1.count) }
        // RSS owner自己的副本、journal原副本和原子替换临时文件都计入空间预算。
        guard try availableBytes() >= oldBytes * 3 + newBytes * 2 + 16 * 1_024 * 1_024 else {
            throw WebDAVBackupError.insufficientSpace
        }
        let journal = fileOverrides.isEmpty && recoveryDirectory == WebDAVRestoreJournal.defaultDirectory
            ? WebDAVRestoreJournal.shared : WebDAVRestoreJournal(directory: recoveryDirectory)
        let token = try await journal.begin(targets: targets)
        var rssStarted = false
        do {
            for (category, data) in files {
                guard let url = file(category) else { throw WebDAVBackupError.corrupt(category) }
                try Task.checkCancellation()
                try data.write(to: url, options: .atomic)
                #if DEBUG
                try await afterCategoryWrite?(category)
                #endif
            }
            // RSSStore自行持有包含正文/变量的原状态，并在落盘异常时回滚。
            if let rssData, let transaction {
                rssStarted = true
                try await rss.restoreBackup(rssData, transaction: transaction)
                #if DEBUG
                try await afterCategoryWrite?(.rss)
                #endif
            }
            return PendingRestore(journal: journal, token: token, targets: targets, restoresRSS: rssData != nil)
        } catch {
            let originalError = error
            var rollbackFailed = false
            if rssStarted, let previousRSS {
                do { try await rss.restoreLocalState(previousRSS) }
                catch {
                    rollbackFailed = true
                    AppLogger.sync("WebDAV RSS owner rollback failed; local copies retained", level: .fault)
                }
            }
            do { try await journal.recover(targets: targets, token: token) }
            catch {
                rollbackFailed = true
                AppLogger.sync("WebDAV file rollback failed; journal retained", level: .fault)
            }
            if rollbackFailed { throw WebDAVBackupError.rollbackFailed }
            throw originalError
        }
    }

    private func reload(_ staged: [(WebDAVBackupCategory, Data)]) async throws {
        let sourceData = fileOverrides.isEmpty ? staged.first { $0.0 == .bookSources }?.1 : nil
        let ruleData = fileOverrides.isEmpty ? staged.first { $0.0 == .replaceRules }?.1 : nil
        let shelfData = staged.first { $0.0 == .bookshelf }?.1

        let sourceStore = sourceData == nil ? nil : await MainActor.run { BookSourceStore.shared }
        let expectedSourceRevision = sourceStore?.mutationRevision
        let preparedSources: [BookSource]?
        if let sourceData {
            preparedSources = try await Task.detached(priority: .utility) { try Self.prepareSources(data: sourceData) }.value
        } else { preparedSources = nil }

        let ruleStore = ruleData == nil ? nil : await MainActor.run { ReplaceRuleStore.shared }
        let expectedRuleRevision: Int?
        if let ruleStore { expectedRuleRevision = await MainActor.run { ruleStore.revision } }
        else { expectedRuleRevision = nil }
        let preparedRules: [ReplaceRule]?
        if let ruleData {
            preparedRules = try await Task.detached(priority: .utility) { try Self.prepareRules(data: ruleData) }.value
        } else { preparedRules = nil }

        let preparedShelf: BookStore.RestoredShelfSnapshot?
        if let shelfData, let bookStore { preparedShelf = try await bookStore.prepareRestoredShelf(shelfData) }
        else { preparedShelf = nil }

        // Nothing is published until every decode/merge is complete and every store still has
        // the revision captured before preparation. The synchronous MainActor section has no
        // suspension point, so edits cannot be overwritten between check and publication.
        try await MainActor.run {
            if let sourceStore, let expectedSourceRevision,
               sourceStore.mutationRevision != expectedSourceRevision { throw RSSImportService.Issue.stalePlan }
            if let ruleStore, let expectedRuleRevision,
               ruleStore.revision != expectedRuleRevision { throw RSSImportService.Issue.stalePlan }
            if let bookStore, let preparedShelf { try bookStore.applyRestoredShelf(preparedShelf) }
            if let sourceStore, let preparedSources, let expectedSourceRevision,
               !sourceStore.applyRestoredSources(preparedSources, expectedMutationRevision: expectedSourceRevision) {
                throw RSSImportService.Issue.stalePlan
            }
            if let ruleStore, let preparedRules, let expectedRuleRevision,
               !ruleStore.applyRestoredRules(preparedRules, expectedRevision: expectedRuleRevision) {
                throw RSSImportService.Issue.stalePlan
            }
        }
    }

    private nonisolated static func prepareSources(data: Data) throws -> [BookSource] {
        try SourcePerfTrace.span("webdav.reload.sources", "main=\(Thread.isMainThread) bytes=\(data.count)", thresholdMs: 0) {
            let incoming = try JSONDecoder().decode([BookSource].self, from: data)
            let deduped = BookSourceStore.dedupedByURL(incoming)
            guard Set(deduped.map(\.id)).count == deduped.count else { throw WebDAVBackupError.corrupt(.bookSources) }
            return deduped
        }
    }

    private nonisolated static func prepareRules(data: Data) throws -> [ReplaceRule] {
        try SourcePerfTrace.span("webdav.reload.rules", "main=\(Thread.isMainThread) bytes=\(data.count)", thresholdMs: 0) {
            let incoming = try JSONDecoder().decode([ReplaceRule].self, from: data)
            return ReplaceRuleStore.deduplicated(incoming)
        }
    }

    func availableBytes() throws -> Int64 {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        let values = try home.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values.volumeAvailableCapacityForImportantUsage ?? 0
    }
}

extension WebDAVManager {
    /// 上传一个新版本。manifest 最后写入；中途失败或取消时，远端只留下不会被列出的残缺目录。
    nonisolated func backupVersion(categories: Set<WebDAVBackupCategory>, local: any WebDAVBackupLocalData,
                                   now: Date = Date()) async throws -> WebDAVBackupManifest {
        guard !categories.isEmpty else { throw WebDAVBackupError.nothingSelected }
        var payloads: [(WebDAVBackupCategory, Data)] = []
        for category in WebDAVBackupCategory.allCases where categories.contains(category) {
            try Task.checkCancellation()
            guard let data = try await local.export(category) else { continue }
            guard data.count <= WebDAVBackupLayout.maximumFileBytes else { throw WebDAVBackupError.tooLarge }
            payloads.append((category, data))
        }
        guard !payloads.isEmpty else { throw WebDAVBackupError.nothingToBackUp }
        let name = WebDAVBackupLayout.name(date: now, deviceID: Self.backupDeviceID)
        let directory = try WebDAVBackupLayout.directory(name)
        try await mkcol(path: "/readerfork-dev/")
        try await mkcol(path: WebDAVBackupLayout.root)
        try await mkcol(path: directory, requireNew: true)
        for (category, data) in payloads {
            try Task.checkCancellation()
            try await put(data: data, path: directory + category.fileName)
        }
        try Task.checkCancellation()
        let (deviceName, version) = await MainActor.run {
            (UIDevice.current.name, Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "")
        }
        let manifest = WebDAVBackupManifest(format: WebDAVBackupManifest.currentFormat, name: name, created: now,
            deviceName: deviceName, appVersion: version,
            files: payloads.map { .init(category: $0.0, size: $0.1.count, sha256: WebDAVBackupLayout.digest($0.1)) })
        try await put(data: try WebDAVBackupLayout.encodeManifest(manifest), path: directory + "manifest.json")
        await MainActor.run { self.lastSyncDate = now }
        return manifest
    }

    /// 已提交（有可解析 manifest）的版本，新到旧，最多最近 50 个。没有备份目录时返回空。
    /// 缺 manifest（上传中断）或 manifest 损坏的目录跳过；认证/网络错误照常抛出，不当成“没有备份”。
    nonisolated func listBackupVersions() async throws -> [WebDAVBackupManifest] {
        let names: [String]
        do { names = try WebDAVBackupLayout.names(fromListing: await propfindListing(path: WebDAVBackupLayout.root)) }
        catch WebDAVError.fileNotFound { return [] }
        var result: [WebDAVBackupManifest] = []
        for name in names.prefix(50) {
            try Task.checkCancellation()
            do { result.append(try await backupManifest(name)) }
            catch WebDAVError.fileNotFound { continue }
            catch let error as WebDAVBackupError {
                AppLogger.sync("WebDAV backup version skipped: \(error)", level: .notice)
                continue
            }
        }
        return result
    }

    nonisolated func backupManifest(_ name: String) async throws -> WebDAVBackupManifest {
        let data = try await get(path: try WebDAVBackupLayout.directory(name) + "manifest.json", maximumBytes: 65_536)
        return try WebDAVBackupLayout.decodeManifest(data, expectedName: name)
    }

    /// 先下载并逐一校验大小、SHA-256 与内容格式，再检查空间，全部通过后才修改本机。
    @discardableResult
    nonisolated func restoreVersion(_ name: String, categories: Set<WebDAVBackupCategory>,
                                    local: any WebDAVBackupLocalData) async throws -> [WebDAVBackupCategory] {
        try Task.checkCancellation()
        guard !categories.isEmpty else { throw WebDAVBackupError.nothingSelected }
        let manifest = try await backupManifest(name)
        let directory = try WebDAVBackupLayout.directory(name)
        var staged: [(WebDAVBackupCategory, Data)] = []
        for entry in manifest.files where categories.contains(entry.category) {
            try Task.checkCancellation()
            let data: Data
            do {
                data = try await get(path: directory + entry.category.fileName, maximumBytes: max(1, entry.size))
            } catch let error as URLError where error.code == .dataLengthExceedsMaximum {
                throw WebDAVBackupError.corrupt(entry.category)
            }
            guard data.count == entry.size, WebDAVBackupLayout.digest(data) == entry.sha256 else {
                throw WebDAVBackupError.corrupt(entry.category)
            }
            try await local.validate(entry.category, data)
            staged.append((entry.category, data))
        }
        guard !staged.isEmpty else { throw WebDAVBackupError.nothingToBackUp }
        let needed = Int64(staged.reduce(0) { $0 + $1.1.count }) * 2 + 16 * 1_024 * 1_024
        guard try local.availableBytes() >= needed else { throw WebDAVBackupError.insufficientSpace }
        // 取消只在修改前生效；开始写入后完成或整体回滚。
        try Task.checkCancellation()
        try await local.apply(staged)
        await MainActor.run { self.lastSyncDate = Date() }
        return staged.map(\.0)
    }
}
