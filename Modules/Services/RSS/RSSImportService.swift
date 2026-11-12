import Foundation

/// 仅配置导入：不执行源脚本、不抓取文章、不打开登录页面。
/// 文件、URL、Share/Open-In共用同一展开、比较与报告路径。
enum RSSImportService {
    enum Input: Sendable {
        case data(Data)
        case file(URL)
        case remote(URL)
        case prepared(Loaded)
    }

    struct Limits: Sendable {
        var bytesPerDocument = 8 * 1024 * 1024
        var totalBytes = 24 * 1024 * 1024
        var documents = 32
        var depth = 4
        var entries = 2000
    }

    enum Issue: String, Error, Sendable {
        case invalidFormat, invalidURL, network, responseTooLarge, documentLimit, depthLimit, entryLimit, repeatedURL
        case stalePlan, persistence
        var message: String {
            switch self {
            case .invalidFormat: localized("訂閱配置格式或欄位類型不正確")
            case .invalidURL: localized("訂閱包網址必須是無帳密的 HTTP 或 HTTPS 網址")
            case .network: localized("訂閱包下載失敗，未執行源腳本")
            case .responseTooLarge: localized("訂閱包超過大小限制")
            case .documentLimit: localized("訂閱包超過請求數量限制")
            case .depthLimit: localized("訂閱包超過展開層級限制")
            case .entryLimit: localized("訂閱包超過項目數量限制")
            case .repeatedURL: localized("重複或循環的訂閱包網址已停止展開")
            case .stalePlan: localized("本地訂閱已變更，請重新比較後再匯入")
            case .persistence: localized("訂閱儲存失敗，請重試；尚未回報儲存成功")
            }
        }
    }

    struct Candidate: Identifiable, Sendable {
        let id = UUID()
        var source: RSSSource?
        var issue: Issue?
        var location: String
    }

    struct Loaded: Sendable {
        var candidates: [Candidate]
        var requests: Int
        var bytes: Int
    }

    enum Disposition: String, Sendable {
        case add, update, unchanged, duplicate, invalid
        var selectable: Bool { self == .add || self == .update }
        var label: String {
            switch self {
            case .add: localized("新增")
            case .update: localized("更新")
            case .unchanged: localized("不變，跳過")
            case .duplicate: localized("重複，跳過")
            case .invalid: localized("無法匯入")
            }
        }
    }

    struct Row: Identifiable, Sendable {
        var id: UUID
        var source: RSSSource?
        var disposition: Disposition
        var issue: Issue?
        var location: String
        var changedFields: Int = 0
        var unknownFields: Int = 0
    }

    struct Snapshot: Sendable {
        var revision: UInt64
        var sources: [RSSSource]
        var folders: [RSSFolder]
    }

    struct Plan: Sendable {
        var snapshot: Snapshot
        var rows: [Row]
        var initialSelection: Set<UUID>
        var additions: Int
        var updates: Int
        var skips: Int
        var errors: Int
    }

    struct Changes: Sendable {
        var revision: UInt64
        var sources: [RSSSource]
        var folders: [RSSFolder]
        var changedIDs: Set<String>
        var added: Int
        var updated: Int
        var skipped: Int
        var errors: Int
    }

    typealias Fetch = @Sendable (URL, Int) async throws -> Data

    nonisolated static func load(_ input: Input, limits: Limits = .init(), fetch: @escaping Fetch = download) async throws -> Loaded {
        let onMain = { Thread.isMainThread }()
        let started = SourcePerfTrace.now
        var loader = Loader(limits: limits, fetch: fetch)
        defer {
            SourcePerfTrace.record("rss.import.load",
                "main=\(onMain) entries=\(loader.candidates.count) bytes=\(loader.bytes) requests=\(loader.visited.count)",
                since: started, thresholdMs: 1, mainThreadStallBreadcrumb: false)
        }
        switch input {
        case .data(let data): try await loader.expand(data, depth: 0, location: "1")
        case .file(let url):
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            let size = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard size.isRegularFile == true, let bytes = size.fileSize, bytes <= limits.bytesPerDocument else {
                throw Issue.responseTooLarge
            }
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            try await loader.expand(data, depth: 0, location: "1")
        case .remote(let url): try await loader.remote(url.absoluteString, depth: 0, location: "1")
        case .prepared(let loaded): return loaded
        }
        try Task.checkCancellation()
        return Loaded(candidates: loader.candidates, requests: loader.visited.count, bytes: loader.bytes)
    }

    nonisolated static func compare(_ loaded: Loaded, with snapshot: Snapshot) async throws -> Plan {
        try Task.checkCancellation()
        return try SourcePerfTrace.span("rss.import.compare", "main=\(Thread.isMainThread) sources=\(snapshot.sources.count) entries=\(loaded.candidates.count)") {
            let existing = Dictionary(grouping: snapshot.sources, by: \.sourceKey)
            let ids = Dictionary(grouping: snapshot.sources, by: \.id)
            var seen = Set<String>()
            let rows = try loaded.candidates.map { candidate -> Row in
                var row = Row(id: candidate.id, source: candidate.source, disposition: .invalid,
                              issue: candidate.issue, location: candidate.location)
                guard var source = candidate.source else { return row }
                row.unknownFields = try LegadoSourceJSONParser.unknownFieldCount(in: source)
                guard seen.insert(source.sourceKey).inserted else { row.disposition = .duplicate; return row }
                guard let matches = existing[source.sourceKey] else { row.disposition = .add; return row }
                guard matches.count == 1, let old = matches.first, ids[old.id]?.count == 1 else {
                    row.issue = .invalidFormat
                    return row
                }
                // 源规则更新，本地组织和用户设置不被外包重置。
                source.id = old.id
                source.name = old.name
                source.sourceGroup = old.sourceGroup
                source.enabled = old.enabled
                source.sortOrder = old.sortOrder
                source.customOrder = old.customOrder
                source.newArticleNotificationsEnabled = old.newArticleNotificationsEnabled
                source.homepageURL = old.homepageURL
                source.customRule = old.customRule
                source.resolvedFeedURL = old.resolvedFeedURL
                source.faviconURL = source.sourceIcon ?? old.faviconURL
                let before = try LegadoSourceJSONParser.exportJSON(from: old)
                let after = try LegadoSourceJSONParser.exportJSON(from: source)
                row.changedFields = Set(before.keys).union(after.keys).filter { key in
                    let a = before[key].map { ["v": $0] } ?? [:]
                    let b = after[key].map { ["v": $0] } ?? [:]
                    return !NSDictionary(dictionary: a).isEqual(to: b)
                }.count
                row.source = source
                row.disposition = row.changedFields == 0 ? .unchanged : .update
                return row
            }
            return Plan(snapshot: snapshot, rows: rows,
                        initialSelection: Set(rows.filter { $0.disposition.selectable }.map(\.id)),
                        additions: rows.filter { $0.disposition == .add }.count,
                        updates: rows.filter { $0.disposition == .update }.count,
                        skips: rows.filter { $0.disposition == .unchanged || $0.disposition == .duplicate }.count,
                        errors: rows.filter { $0.disposition == .invalid }.count)
        }
    }

    nonisolated static func changes(for plan: Plan, selected: Set<UUID>) async throws -> Changes {
        try Task.checkCancellation()
        return SourcePerfTrace.span("rss.import.merge", "main=\(Thread.isMainThread) entries=\(plan.rows.count)") {
            var result = Changes(revision: plan.snapshot.revision, sources: plan.snapshot.sources,
                                 folders: plan.snapshot.folders, changedIDs: [], added: 0, updated: 0, skipped: 0, errors: 0)
            let positions = result.sources.enumerated().reduce(into: [String: Int]()) { $0[$1.element.id] = $1.offset }
            var groupNames = Set(result.folders.map { $0.name.lowercased() })
            var nextOrder = (result.sources.map(\.sortOrder).max() ?? -1) + 1
            var nextFolderOrder = (result.folders.map(\.sortOrder).max() ?? -1) + 1
            for row in plan.rows {
                guard selected.contains(row.id), row.disposition.selectable, var source = row.source else {
                    if row.disposition == .invalid { result.errors += 1 } else { result.skipped += 1 }
                    continue
                }
                if row.disposition == .update, let index = positions[source.id] {
                    result.sources[index] = source
                    result.updated += 1
                } else {
                    source.sortOrder = nextOrder
                    nextOrder += 1
                    result.sources.append(source)
                    result.added += 1
                    if let group = source.sourceGroup?.trimmingCharacters(in: .whitespacesAndNewlines),
                       !group.isEmpty, groupNames.insert(group.lowercased()).inserted {
                        result.folders.append(RSSFolder(name: group, sortOrder: nextFolderOrder))
                        nextFolderOrder += 1
                    }
                }
                result.changedIDs.insert(source.id)
            }
            return result
        }
    }

    /// 不继承源的Cookie、Authorization或登录信息，导入包下载并非源运行时请求。
    nonisolated static func download(_ url: URL, maximumBytes: Int) async throws -> Data {
        guard validURL(url) else { throw Issue.invalidURL }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 40
        let session = URLSession(configuration: configuration, delegate: ImportRedirectPolicy(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (stream, response) = try await session.bytes(for: request)
        defer { stream.task.cancel() }
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else { throw Issue.network }
        guard response.expectedContentLength <= maximumBytes else { throw Issue.responseTooLarge }
        var data = Data()
        for try await byte in stream {
            if data.count % 16384 == 0 { try Task.checkCancellation() }
            guard data.count < maximumBytes else { throw Issue.responseTooLarge }
            data.append(byte)
        }
        return data
    }

    fileprivate static func validURL(_ url: URL) -> Bool {
        ["http", "https"].contains(url.scheme?.lowercased() ?? "") && url.host?.isEmpty == false
            && url.user == nil && url.password == nil
    }

    private struct Loader {
        let limits: Limits
        let fetch: Fetch
        var candidates: [Candidate] = []
        var visited: Set<String> = []
        var bytes = 0
        var limited = false

        mutating func issue(_ issue: Issue, _ location: String) {
            candidates.append(Candidate(issue: issue, location: location))
        }

        mutating func remote(_ raw: String, depth: Int, location: String) async throws {
            guard !limited else { return }
            guard depth <= limits.depth else { issue(.depthLimit, location); return }
            guard let url = URL(string: raw), RSSImportService.validURL(url) else { issue(.invalidURL, location); return }
            var key = URLComponents(url: url, resolvingAgainstBaseURL: false)!
            key.fragment = nil // 包下载去环；绝不用于源sourceKey。
            let identity = key.url!.absoluteString
            guard !visited.contains(identity) else { issue(.repeatedURL, location); return }
            guard visited.count < limits.documents else { issue(.documentLimit, location); limited = true; return }
            visited.insert(identity)
            do {
                try Task.checkCancellation()
                let data = try await fetch(url, min(limits.bytesPerDocument, max(0, limits.totalBytes - bytes)))
                try Task.checkCancellation()
                try await expand(data, depth: depth, location: location)
            } catch is CancellationError { throw CancellationError() }
            catch {
                if Task.isCancelled { throw CancellationError() }
                issue((error as? Issue) ?? .network, location)
            }
        }

        mutating func expand(_ data: Data, depth: Int, location: String) async throws {
            try Task.checkCancellation()
            guard !limited else { return }
            guard data.count <= limits.bytesPerDocument, data.count <= limits.totalBytes - bytes else {
                issue(.responseTooLarge, location); limited = true; return
            }
            bytes += data.count
            let raw: Any
            do {
                raw = try SourcePerfTrace.span("rss.import.decode", "main=\(Thread.isMainThread) bytes=\(data.count)") {
                    try JSONSerialization.jsonObject(with: data)
                }
            } catch { issue(.invalidFormat, location); return }
            if let wrapper = raw as? [String: Any], let urls = wrapper["sourceUrls"] {
                guard let entries = urls as? [Any] else { issue(.invalidFormat, location); return }
                for (index, entry) in entries.enumerated() {
                    guard !limited else { break }
                    guard candidates.count < limits.entries else { issue(.entryLimit, location); limited = true; break }
                    guard let value = entry as? String else { issue(.invalidURL, "\(location).\(index + 1)"); continue }
                    try await remote(value, depth: depth + 1, location: "\(location).\(index + 1)")
                }
                return
            }
            let entries: [Any]
            if let array = raw as? [Any] { entries = array }
            else if let object = raw as? [String: Any] { entries = [object] }
            else { issue(.invalidFormat, location); return }
            for (index, entry) in entries.enumerated() {
                try Task.checkCancellation()
                guard candidates.count < limits.entries else { issue(.entryLimit, location); limited = true; break }
                let path = "\(location).\(index + 1)"
                guard let object = entry as? [String: Any] else { issue(.invalidFormat, path); continue }
                do { candidates.append(Candidate(source: try LegadoSourceJSONParser.parseSource(from: object), location: path)) }
                catch { issue(.invalidFormat, path) }
            }
        }
    }
}

private final class ImportRedirectPolicy: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var redirects = 0

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        let allowed = lock.withLock { redirects += 1; return redirects <= 4 }
        guard allowed, let url = request.url, RSSImportService.validURL(url),
              !(response.url?.scheme == "https" && url.scheme == "http") else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }
}
