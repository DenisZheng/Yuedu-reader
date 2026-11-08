import Foundation
import Observation

/// 单个订阅浏览流程的临时分页状态；文章/状态/落盘始终由RSSStore拥有。
/// 一个请求一个fetcher快照，过期请求不能发布到新分类或查询，也不能提交旧页。
@MainActor
@Observable
final class RSSFeedSession {
    enum End: Equatable { case empty, duplicate, loop, budget }
    private struct Request {
        let page: Int
        let url: String?
        let append: Bool
        let entry: RSSSortEntry?
        let key: String?
    }

    private(set) var scope: RSSArticleScope
    private(set) var entries: [RSSSortEntry] = []
    private(set) var selectedEntry: RSSSortEntry?
    private(set) var searchKey: String?
    private(set) var currentPage = 0
    private(set) var nextURL: String?
    private(set) var end: End?
    private(set) var isLoading = false
    private(set) var error: String?
    private(set) var wasCancelled = false
    private(set) var openTarget: RSSOpenTarget?
    private(set) var webPageURL: InAppWebURL?
    private(set) var webPageFallbackURL: InAppWebURL?
    var canLoadMore: Bool { nextURL != nil && end == nil && !isLoading }
    var canRetry: Bool { failedRequest != nil && !isLoading }

    let sourceID: String
    private let store: RSSStore
    private let session: URLSession
    private let maxPages: Int
    private var activeRevision: UInt64?
    private var generation: UInt64 = 0
    private var task: Task<Void, Never>?
    private var failedRequest: Request?
    private var visited: Set<String> = []
    private var loadedIDs: Set<String> = []

    init(source: RSSSource, store: RSSStore, session: URLSession = .shared, maxPages: Int = 50) {
        self.sourceID = source.id
        self.store = store
        self.session = session
        self.maxPages = max(1, maxPages)
        // 规则列表既有默认分类的身份保持不变；普通Feed仍为.feed。
        self.scope = source.isLegadoRuleBased ? .category(.init(name: "", url: source.sourceKey)) : .feed
    }

    func refresh(entry: RSSSortEntry? = nil, key: String? = nil) async {
        let key = key?.trimmingCharacters(in: .whitespacesAndNewlines)
        let query = key?.isEmpty == false ? key : nil
        if isLoading, selectedEntry == entry, searchKey == query,
           activeRevision == store.configurationRevision, task?.isCancelled != true { return }
        cancel()
        selectedEntry = entry
        searchKey = query
        if let source = store.source(id: sourceID) {
            scope = query.map(RSSArticleScope.search) ?? entry.map(RSSArticleScope.category)
                ?? (source.isLegadoRuleBased ? .category(.init(name: "", url: source.sourceKey)) : .feed)
        }
        currentPage = 0
        webPageURL = nil
        openTarget = nil
        nextURL = nil
        visited = []
        loadedIDs = []
        end = nil
        failedRequest = nil
        await load(.init(page: 1, url: nil, append: false, entry: entry, key: query))
    }

    func nextPage() async {
        guard canLoadMore, let nextURL else { return }
        await load(.init(page: currentPage + 1, url: nextURL, append: true, entry: selectedEntry, key: searchKey))
    }

    func retry() async {
        guard !isLoading, let failedRequest else { return }
        await load(failedRequest)
    }

    func cancel() {
        generation &+= 1
        task?.cancel()
        task = nil
        if isLoading { wasCancelled = true }
        isLoading = false
    }

    private func load(_ request: Request) async {
        guard !isLoading, let source = store.source(id: sourceID), let ticket = store.requestTicket(for: sourceID) else { return }
        generation &+= 1
        let id = generation
        let resolvedEntries = entries.isEmpty || activeRevision != store.configurationRevision ? nil : entries
        activeRevision = store.configurationRevision
        isLoading = true
        failedRequest = request
        error = nil
        wasCancelled = false
        webPageFallbackURL = nil
        let metadata = scope == .feed && !request.append ? store.feedMetadata(for: sourceID) : nil
        let work = Task { [weak self, store, session] in
            let fetcher = RSSFetcher(session: session)
            await fetcher.fetchItems(from: source, metadata: metadata, sortEntry: request.entry, owner: store,
                                     page: request.page, key: request.key, requestURL: request.url, resolvedEntries: resolvedEntries)
            guard let self, id == self.generation else { return }
            defer { self.isLoading = false; self.task = nil }
            guard !Task.isCancelled, store.accepts(ticket), store.source(id: source.id) == source else {
                self.wasCancelled = true
                self.failedRequest = request
                return
            }
            self.entries = fetcher.sortEntries
            self.openTarget = fetcher.openTarget
            self.webPageURL = fetcher.webPageURL
            self.webPageFallbackURL = fetcher.webPageFallbackURL
            if let message = fetcher.error {
                self.error = message
                self.failedRequest = request
                return
            }
            if fetcher.openTarget != nil { self.failedRequest = nil; return }
            guard let response = fetcher.response else {
                self.wasCancelled = true
                self.failedRequest = request
                return
            }
            let resultScope = fetcher.listPage?.scope ?? .feed
            guard RSSFeedRefreshService.apply(fetcher, source: source, ticket: ticket, store: store,
                                               scope: resultScope, append: request.append) else { return }
            self.scope = resultScope
            self.failedRequest = nil
            self.currentPage = request.page
            if case .notModified = response { return }
            let ids = Set(fetcher.items.map(\.id))
            if ids.isEmpty { self.end = .empty }
            else if request.append, ids.isSubset(of: self.loadedIDs) { self.end = .duplicate }
            self.loadedIDs.formUnion(ids)
            if self.currentPage >= self.maxPages, fetcher.listPage?.nextURL != nil { self.end = .budget }
            if let page = fetcher.listPage {
                self.visited.insert(page.requestURL)
                self.visited.insert(page.finalURL)
                if let url = request.url { self.visited.insert(url) }
                let usesPageTemplate = source.ruleNextPage?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() == "PAGE"
                if let next = page.nextURL, !usesPageTemplate, self.visited.contains(next) { self.end = .loop }
                self.nextURL = self.end == nil ? page.nextURL : nil
            } else { self.nextURL = nil }
        }
        task = work
        await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
    }
}
