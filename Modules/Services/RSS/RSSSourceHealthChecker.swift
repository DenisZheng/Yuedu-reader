import Foundation
import Observation

/// 活性只验证可执行入口/首列表，不等价于所有文章或媒体可用；结果仅保存在本次管理会话。
@MainActor @Observable
final class RSSSourceHealthChecker {
    enum Outcome: Equatable, Sendable {
        case list(Int)
        case emptyList
        case webReachable
        case generatedPage
        case mediaEntry
        case interactionRequired
        case httpFailure(Int)
        case failed(String)
        case cancelled
        var kind: Kind {
            switch self {
            case .list: .list
            case .emptyList: .emptyList
            case .webReachable: .webReachable
            case .generatedPage: .generatedPage
            case .mediaEntry: .mediaEntry
            case .interactionRequired: .interactionRequired
            case .httpFailure(let status): .httpFailure(status)
            case .failed: .failed
            case .cancelled: .cancelled
            }
        }

        var title: String {
            switch self {
            case .list(let count): String(format: localized("首頁可用：%d 個條目"), count)
            case .httpFailure(let status): String(format: localized("RSS 請求失敗：HTTP %d"), status)
            case .failed(let reason): reason
            default: kind.title
            }
        }

        enum Kind: Hashable, Sendable {
            case httpFailure(Int)
            case failed, list, emptyList, webReachable, generatedPage, mediaEntry, interactionRequired, cancelled

            private static let otherOrder: [Self] = [
                .failed, .list, .emptyList, .webReachable, .generatedPage, .mediaEntry, .interactionRequired, .cancelled
            ]

            static func ordered(_ kinds: Set<Self>) -> [Self] {
                let statuses = kinds.compactMap { kind -> Int? in
                    if case .httpFailure(let status) = kind { return status }
                    return nil
                }
                // 直接在「全部」旁列出已出现的HTTP状态；无状态码错误仍归入普通失败。
                return statuses.sorted().map(Self.httpFailure) + otherOrder.filter(kinds.contains)
            }

            var identifier: String {
                switch self {
                case .httpFailure(let status): "http-\(status)"
                case .failed: "failed"
                case .list: "list"
                case .emptyList: "emptyList"
                case .webReachable: "webReachable"
                case .generatedPage: "generatedPage"
                case .mediaEntry: "mediaEntry"
                case .interactionRequired: "interactionRequired"
                case .cancelled: "cancelled"
                }
            }

            var isFailure: Bool {
                if case .httpFailure = self { return true }
                return self == .failed
            }

            var title: String {
                switch self {
                case .httpFailure(let status): String(format: localized("HTTP %d"), status)
                case .failed: localized("驗證失敗")
                case .list: localized("首頁有條目")
                case .emptyList: localized("首頁解析成功，列表為空")
                case .webReachable: localized("啟動網頁可達（未驗證媒體）")
                case .generatedPage: localized("啟動頁已生成（未驗證網路）")
                case .mediaEntry: localized("媒體入口（需人工播放驗證）")
                case .interactionRequired: localized("需要登入或人工驗證")
                case .cancelled: localized("已取消")
                }
            }
        }
    }

    struct SelectionGroup: Identifiable, Sendable {
        let kind: Outcome.Kind
        let sourceIDs: Set<String>
        var id: Outcome.Kind { kind }
    }

    private struct CheckedSource: Sendable {
        let source: RSSSource
        let ticket: RSSRequestTicket
    }

    private struct QueuedSource: Sendable {
        let source: RSSSource
        let feedHost: String?
    }

    private(set) var results: [String: Outcome] = [:]
    private(set) var isRunning = false
    private(set) var completed = 0
    private(set) var total = 0
    /// 结果页只在一批完成或停止后重建，不随每条进度重新筛选整库。
    private(set) var resultVersion: UInt64 = 0
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var activeIDs: Set<String> = []
    @ObservationIgnored private var checkedSources: [String: CheckedSource] = [:]

    func start(sources: [RSSSource], owner: RSSStore, session: URLSession? = nil) {
        cancel()
        let previous = task
        total = sources.count; completed = 0
        guard !sources.isEmpty else { return }
        // 整批排队时先撤回旧结果；取消后未轮到的源不冒充本次已验证。
        if !checkedSources.isEmpty {
            for source in sources where checkedSources.removeValue(forKey: source.id) != nil {
                results[source.id] = nil
            }
        }
        isRunning = true
        let version = generation
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 12
        config.timeoutIntervalForResource = 20
        config.httpMaximumConnectionsPerHost = 1
        config.urlCache = nil
        let requests = session ?? URLSession(configuration: config)
        task = Task { [weak self] in
            defer { if session == nil { requests.invalidateAndCancel() } }
            // 重开批次时，先等取消沿请求/脚本真正收口。
            await previous?.value
            guard let self, !Task.isCancelled, generation == version else { return }
            var pending = (await Self.prepareQueue(sources))[...]
            let hostLimit = PerHostSemaphore()
            await withTaskGroup(of: (CheckedSource, Outcome).self) { group in
                var feedHosts: [String: String] = [:]
                while !Task.isCancelled, generation == version {
                    while activeIDs.count < 2, let next = pending.first {
                        // 仍按原顺序：同主机不叠加，规则/登录/不确定的源须等其它检查结束。
                        if !activeIDs.isEmpty {
                            guard let host = next.feedHost, feedHosts.count == activeIDs.count,
                                  !feedHosts.values.contains(host) else { break }
                        }
                        pending.removeFirst()
                        let source = next.source
                        guard let ticket = owner.requestTicket(for: source.id, allowsDisabledDiagnostic: true),
                              owner.source(id: source.id) == source else { continue }
                        let checked = CheckedSource(source: source, ticket: ticket)
                        checkedSources[source.id] = checked
                        activeIDs.insert(source.id)
                        feedHosts[source.id] = next.feedHost
                        let limit = next.feedHost == nil ? nil : hostLimit
                        group.addTask {
                            let outcome = await SourceRequestExecutor.$serialHosts.withValue(limit) {
                                await Self.check(source: source, owner: owner, session: requests)
                            }
                            return (checked, outcome)
                        }
                    }
                    guard let (checked, outcome) = await group.next(),
                          !Task.isCancelled, generation == version else { return }
                    let id = checked.source.id
                    activeIDs.remove(id)
                    feedHosts[id] = nil
                    // 删除、改配置或登录变化后，不把晚到检查结果贴到新源上。
                    if owner.accepts(checked.ticket), owner.source(id: id) == checked.source { results[id] = outcome }
                    completed += 1
                }
            }
            guard !Task.isCancelled, generation == version else { return }
            isRunning = false; task = nil
            resultVersion &+= 1
        }
    }

    func cancel() {
        generation &+= 1
        if isRunning { resultVersion &+= 1 }
        // 保留已取消的Task句柄供调用者等待真正收口；下一次start会替换它。
        task?.cancel()
        for id in activeIDs { results[id] = .cancelled }
        activeIDs.removeAll()
        isRunning = false
    }

    nonisolated private static func prepareQueue(_ sources: [RSSSource]) async -> [QueuedSource] {
        SourcePerfTrace.span("rss.health.queue", "main=\(Thread.isMainThread) sources=\(sources.count)") {
            var queue: [QueuedSource] = []
            queue.reserveCapacity(sources.count)
            for source in sources {
                guard !Task.isCancelled else { return [] }
                queue.append(.init(source: source, feedHost: plainFeedHost(for: source)))
            }
            return queue
        }
    }

    /// 并行只用于静态HTTP(S)标准Feed；拿不准仍走原串行路径，不改变URL、规则或认证。
    nonisolated private static func plainFeedHost(for source: RSSSource) -> String? {
        guard !source.usesLegadoRuntime, !source.singleUrl, !source.enabledCookieJar,
              source.contentType == nil || source.contentType == .web,
              source.preservedLegadoFields == nil,
              [source.loginUrl, source.loginUi, source.coverDecodeJs, source.startJs, source.preloadJs, source.injectJs,
               source.shouldOverrideUrlLoading, source.customRule, source.ruleNextPage, source.nextContentUrl, source.variable]
                .allSatisfy({ $0?.isEmpty != false }),
              LoginManager.shared.getLoginHeader(sourceUrl: RSSRuntime.authenticationKey(for: source)) == nil else { return nil }
        func staticHost(_ raw: String) -> String? {
            guard raw.range(of: "@js:", options: .caseInsensitive) == nil, !AnalyzeUrl.hasOptions(raw),
                  !raw.contains(where: { "{}<>".contains($0) }),
                  let url = URL(string: raw, encodingInvalidCharacters: false),
                  SourceRequestHeaderScope.origin(url) != nil, url.user == nil, url.password == nil else { return nil }
            return PerHostSemaphore.hostKey(for: url)
        }
        guard let sourceHost = staticHost(source.sourceKey) else { return nil }
        // 标准Feed检查优先用发现的地址，不能按原始sourceKey的主机限流。
        if let feed = source.resolvedFeedURL, feed != source.sourceKey { return staticHost(feed) }
        return sourceHost
    }

    /// 调用者需要收口运行时可等待已启动任务；不轮询结果或猜测延迟。
    func waitForCompletion() async { await task?.value }

    func retainResults(for sources: [RSSSource]) {
        guard !checkedSources.isEmpty else { return }
        let current = Dictionary(sources.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for id in Array(checkedSources.keys) where checkedSources[id]?.source != current[id] {
            results[id] = nil; checkedSources[id] = nil
        }
    }

    func selectionGroups(in sources: [RSSSource], revisions: RSSStore.RequestRevisions) async -> [SelectionGroup] {
        guard !isRunning else { return [] }
        let outcomes = results, checks = checkedSources
        return await Task.detached(priority: .userInitiated) {
            SourcePerfTrace.span("rss.health.selection", "main=\(Thread.isMainThread) sources=\(sources.count)") {
                var idsByKind: [Outcome.Kind: Set<String>] = [:]
                for source in sources {
                    guard let outcome = outcomes[source.id], let check = checks[source.id],
                          check.source == source, revisions.matches(check.ticket) else { continue }
                    idsByKind[outcome.kind, default: []].insert(source.id)
                }
                return Outcome.Kind.ordered(Set(idsByKind.keys)).compactMap { kind in
                    idsByKind[kind].map { SelectionGroup(kind: kind, sourceIDs: $0) }
                }
            }
        }.value
    }

    private struct Deadline: Error {}
    /// 30秒是单源整体截止，不是等待界面稳定；取消会沿RSSRuntime传到请求和JS会话。
    static func check(source: RSSSource, owner: RSSStore, session: URLSession, timeout: Duration = .seconds(30)) async -> Outcome {
        do {
            return try await withThrowingTaskGroup(of: Outcome.self) { group in
                defer { group.cancelAll() }
                group.addTask {
                    try await RSSRuntime.$isAvailabilityCheck.withValue(true) {
                        try await probe(source: source, owner: owner, session: session)
                    }
                }
                group.addTask { try await Task.sleep(for: timeout); throw Deadline() }
                guard let result = try await group.next() else { throw CancellationError() }
                return result
            }
        } catch is CancellationError { return .cancelled }
        catch is Deadline { return .failed(localized("校驗超時")) }
        catch ScraperError.interactionRequired { return .interactionRequired }
        catch ScraperError.httpStatus(401) { return .interactionRequired }
        catch ScraperError.httpStatus(403) { return .interactionRequired }
        catch ScraperError.httpStatus(let status) { return .httpFailure(status) }
        catch is SourceRuntimeRequirement { return .interactionRequired }
        catch { return .failed(RSSSourceDebugger.describe(error)) }
    }

    /// 先遵从singleUrl/startHtml；否则取第一个分类的首列表。标准Feed也通过共享请求后解析。
    /// 不写文章/已读状态，不自动搜索、分页、打开系统浏览器或下载正文/图片/音视频。
    nonisolated private static func probe(source: RSSSource, owner: RSSStore, session: URLSession) async throws -> Outcome {
        if let target = try await RSSOpenTarget.resolve(source: source, owner: owner, session: session) {
            switch target {
            case .request(let request, let context):
                // 已知媒体入口不下载文件；未知类型只请求首文档，不加载其子资源。
                let mediaExtensions: Set<String> = ["mp4", "m4v", "mov", "m3u8", "mp3", "m4a", "aac", "flac", "jpg", "jpeg", "png", "gif", "webp", "svg"]
                if let url = request.url, mediaExtensions.contains(url.pathExtension.lowercased()) { return .mediaEntry }
                let document = try await RSSOpenTarget.loadDocument(request, context: context, source: source, owner: owner, session: session)
                guard !document.data.isEmpty else { throw ScraperError.httpError }
                if document.mimeType.hasPrefix("audio/") || document.mimeType.hasPrefix("video/") || document.mimeType.hasPrefix("image/") {
                    return .mediaEntry
                }
                return .webReachable
            case .html(let html, _), .articleHTML(let html, _):
                guard !html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ScraperError.httpError }
                return .generatedPage
            case .external: return .interactionRequired
            }
        }
        if source.isLegadoRuleBased {
            let entries = try await LegadoRSSScraper.resolveSortEntries(for: source, owner: owner, requestSession: session)
            let page = try await LegadoRSSScraper.fetchListPage(source: source, entry: entries.first, page: 1, owner: owner, requestSession: session)
            return page.items.isEmpty ? .emptyList : .list(page.items.count)
        }
        let runtime = try await RSSRuntime.make(source: source, owner: owner, requestSession: session)
        return try await runtime.run { host in
            let page = try await host.fetchRulePage(ruleURL: source.resolvedFeedURL ?? source.sourceKey, page: 1, isPrimaryRequest: true)
            guard (200..<300).contains(page.status) else { throw ScraperError.httpStatus(page.status) }
            return try await host.run { _ in
                guard let feed = RSSFeedParser.parse(data: RSSFeedParser.data(fromDecodedText: page.body), url: page.url) else {
                    throw ScraperError.invalidRule("feed")
                }
                return feed.items.isEmpty ? .emptyList : .list(feed.items.count)
            }
        }
    }
}
