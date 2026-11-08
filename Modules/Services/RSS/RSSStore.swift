import Foundation
import Combine
import SwiftUI

@MainActor
final class RSSStore: ObservableObject {
    static let shared = RSSStore()

    @Published var sources: [RSSSource] = [] { didSet {
        configurationRevision &+= 1
        invalidateRuntimes()
    } }
    @Published var folders: [RSSFolder] = [] { didSet {
        configurationRevision &+= 1
        invalidateRuntimes()
    } }
    private(set) var configurationRevision: UInt64 = 0
    private var authenticationRevisions: [String: UInt64] = [:]
    private var sourceVariables: [String: [String: String]] = [:]
    private var sourceOptionJSON: [String: String] = [:]
    let runtimeIdentity = UUID().uuidString
    private final class RuntimeReference {
        weak var value: RSSRuntimeState?
        init(_ value: RSSRuntimeState) { self.value = value }
    }
    // 生命周期登记，不是缓存。弱引用也能使被共享LRU淘汰但仍在请求中的会话失效。
    private var runtimes: [String: [RuntimeReference]] = [:]

    func registerRuntime(_ value: RSSRuntimeState, source: RSSSource, ticket: RSSRequestTicket) -> Bool {
        guard accepts(ticket), self.source(id: source.id) == source else { return false }
        var entries = (runtimes[source.id] ?? []).filter { $0.value != nil }
        if !entries.contains(where: { $0.value === value }) { entries.append(RuntimeReference(value)) }
        runtimes[source.id] = entries
        return true
    }

    private func invalidateRuntimes(for sourceID: String? = nil) {
        let keys = sourceID.map { [$0] } ?? Array(runtimes.keys)
        for key in keys {
            for entry in runtimes.removeValue(forKey: key) ?? [] { entry.value?.invalidate() }
        }
    }
    @Published private var cachedArticlesBySource: [String: [RSSArticleRecord]] = [:] { didSet { contentRevision &+= 1 } }
    @Published private var articleStatuses: [String: RSSArticleStatus] = [:] { didSet { contentRevision &+= 1 } }
    private var contentRevision: UInt64 = 0
    // 仅owner派生索引：避免状态动作逐次扫描全库；不持有另一份内容/状态。
    private var articleLocations: [String: (sourceID: String, index: Int)] = [:]
    private var legacyArticleIDs: [String: Set<String>] = [:]
    private var unreadBySource: [String: Int] = [:]
    @Published private var feedMetadataBySource: [String: RSSFeedFetchMetadata] = [:]

    private let sourceStorageURL: URL
    private let folderStorageURL: URL
    private let articleStorageURL: URL
    private let statusStorageURL: URL
    private let feedMetadataStorageURL: URL

    init(storageDirectory: URL = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first!) {
        sourceStorageURL = storageDirectory.appendingPathComponent("rss_sources.json")
        folderStorageURL = storageDirectory.appendingPathComponent("rss_folders.json")
        articleStorageURL = storageDirectory.appendingPathComponent("rss_articles.json")
        statusStorageURL = storageDirectory.appendingPathComponent("rss_article_status.json")
        feedMetadataStorageURL = storageDirectory.appendingPathComponent("rss_feed_metadata.json")
        load()
    }

    func addSource(_ source: RSSSource) {
        if let groupName = normalizedFolderName(source.sourceGroup) {
            ensureFolderExists(named: groupName)
        }
        sources.append(source)
        save([.sources, .folders])
    }

    func addSources(_ newSources: [RSSSource]) -> Int {
        addSourcesReturningAdded(newSources).count
    }

    func addSourcesReturningAdded(_ newSources: [RSSSource]) -> [RSSSource] {
        guard !newSources.isEmpty else { return [] }
        var existingURLs = Set(sources.map(\.url))
        var addedSources: [RSSSource] = []

        for var source in newSources where !existingURLs.contains(source.url) {
            let groupName = normalizedFolderName(source.sourceGroup)
            source.sourceGroup = groupName
            if let groupName {
                ensureFolderExists(named: groupName)
            }
            source.sortOrder = nextSourceSortOrder(inFolderNamed: groupName)
            sources.append(source)
            existingURLs.insert(source.url)
            addedSources.append(source)
        }

        if !addedSources.isEmpty {
            save([.sources, .folders])
        }
        return addedSources
    }

    func removeSource(at offsets: IndexSet) {
        let ids = offsets.compactMap { index -> String? in
            guard sources.indices.contains(index) else { return nil }
            return sources[index].id
        }
        removeSources(ids: ids)
    }

    func removeSources(ids: [String]) {
        guard !ids.isEmpty else { return }
        let sourceIDs = Set(ids)
        let articleIDs = Set(sourceIDs.flatMap { cachedArticlesBySource[$0]?.map(\.id) ?? [] })
        let legacyIDs = Set(sourceIDs.flatMap { cachedArticlesBySource[$0]?.compactMap(\.legacyID) ?? [] })

        sources.removeAll { sourceIDs.contains($0.id) }
        for sourceID in sourceIDs {
            indexArticles([], replacing: cachedArticlesBySource[sourceID] ?? [], for: sourceID)
            cachedArticlesBySource[sourceID] = nil
            feedMetadataBySource[sourceID] = nil
            sourceVariables[sourceID] = nil
            sourceOptionJSON[sourceID] = nil
            authenticationRevisions[sourceID, default: 0] &+= 1
        }
        articleStatuses = articleStatuses.filter { key, value in
            !articleIDs.contains(key) && !sourceIDs.contains(value.sourceID ?? "")
                && !(legacyIDs.contains(key) && legacyArticleIDs[key] == nil)
        }
        save()
    }

    func updateSource(_ source: RSSSource) {
        if let index = sources.firstIndex(where: { $0.id == source.id }) {
            var normalized = source
            normalized.sourceGroup = normalizedFolderName(source.sourceGroup)
            if let groupName = normalized.sourceGroup {
                ensureFolderExists(named: groupName)
            }
            guard sources[index] != normalized else { return }
            clearFeedMetadata(for: source.id)
            sources[index] = normalized
            save([.sources, .folders])
        }
    }

    func applyResolvedFeedURL(_ feedURL: String?, homepageURL: String?, to sourceID: String) {
        guard let index = sources.firstIndex(where: { $0.id == sourceID }) else { return }

        var source = sources[index]
        var didChange = false

        if let feedURL,
           !feedURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           source.resolvedFeedURL != feedURL {
            source.resolvedFeedURL = feedURL
            didChange = true
        }

        if let homepageURL,
           !homepageURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           source.homepageURL?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
            source.homepageURL = homepageURL
            didChange = true
        }

        if didChange {
            sources[index] = source
            saveRefreshResult(.sources)
        }
    }

    func addFolder(named name: String) -> Bool {
        guard let name = normalizedFolderName(name),
              !folders.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) else {
            return false
        }

        folders.append(RSSFolder(name: name, sortOrder: nextFolderSortOrder()))
        save()
        return true
    }

    func updateFolder(_ folder: RSSFolder) {
        guard let index = folders.firstIndex(where: { $0.id == folder.id }),
              let newName = normalizedFolderName(folder.name) else {
            return
        }

        let oldName = folders[index].name
        folders[index].name = newName
        for sourceIndex in sources.indices where sourceGroup(sources[sourceIndex].sourceGroup, matches: oldName) {
            sources[sourceIndex].sourceGroup = newName
        }
        save()
    }

    func removeFolder(_ folder: RSSFolder, deleteSources: Bool = true) {
        guard let index = folders.firstIndex(where: { $0.id == folder.id }) else { return }
        folders.remove(at: index)
        if deleteSources {
            let ids = sources.filter { sourceGroup($0.sourceGroup, matches: folder.name) }.map(\.id)
            if ids.isEmpty {
                save()
            } else {
                removeSources(ids: ids)
            }
        } else {
            for sourceIndex in sources.indices where sourceGroup(sources[sourceIndex].sourceGroup, matches: folder.name) {
                sources[sourceIndex].sourceGroup = nil
            }
            save()
        }
    }

    func rootSources() -> [RSSSource] {
        sources(inFolderNamed: nil)
    }

    func sources(in folder: RSSFolder) -> [RSSSource] {
        sources(inFolderNamed: folder.name)
    }

    func moveSources(inFolderNamed folderName: String?, fromOffsets sourceOffsets: IndexSet, toOffset destination: Int) {
        var ordered = sources(inFolderNamed: normalizedFolderName(folderName))
        ordered.move(fromOffsets: sourceOffsets, toOffset: destination)

        for (sortOrder, source) in ordered.enumerated() {
            guard let index = sources.firstIndex(where: { $0.id == source.id }) else { continue }
            sources[index].sortOrder = sortOrder
        }
        save()
    }

    func moveFolders(fromOffsets offsets: IndexSet, toOffset destination: Int) {
        var ordered = orderedFolders()
        ordered.move(fromOffsets: offsets, toOffset: destination)

        for (sortOrder, folder) in ordered.enumerated() {
            guard let index = folders.firstIndex(where: { $0.id == folder.id }) else { continue }
            folders[index].sortOrder = sortOrder
        }
        save()
    }

    func orderedFolders() -> [RSSFolder] {
        folders.sorted { lhs, rhs in
            if lhs.sortOrder == rhs.sortOrder {
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
            return lhs.sortOrder < rhs.sortOrder
        }
    }

    func nextSourceSortOrder(in folder: RSSFolder?) -> Int {
        nextSourceSortOrder(inFolderNamed: folder?.name)
    }

    @discardableResult
    func mergeFetchedItems(_ items: [RSSItem], for sourceID: String,
                           scope: RSSArticleScope = .feed, append: Bool = false) -> [RSSArticleRecord] {
        guard source(id: sourceID) != nil else { return [] }
        let scope = items.first?.scope ?? scope
        let items = items.map { $0.identified(sourceID: sourceID, scope: scope) }
        let existingRecords = cachedArticlesBySource[sourceID] ?? []

        // Real-world feeds (and Legado custom-rule sources whose uniqueID
        // falls back to link then title) routinely emit duplicate GUIDs, which
        // become duplicate RSSItem.id. A prior build persisted those duplicates
        // into cachedArticlesBySource, and the uniqueKeysWithValues initializer
        // traps on duplicate keys — Crashlytics 5dd3bb... (main-thread
        // assertionFailure inside _NativeDictionary.merge). Build the lookup
        // crash-safely so an already-corrupted cache self-heals on the next
        // refresh instead of taking the app down. This is an invariant guard
        // for cached article records (keyed by id must be unique); it is not a
        // retry/alternate path and stays even after the parser is hardened,
        // because feed GUIDs are external data we cannot trust to be unique.
        let existingByID = Dictionary(existingRecords.map { ($0.id, $0) },
                                      uniquingKeysWith: { first, _ in first })

        let hadExistingCache = !existingRecords.isEmpty
        let fetchedAt = Date()

        // Same root cause: dedupe incoming items by id (keep first occurrence /
        // feed order) so we never persist duplicate records in the first place.
        var seenIDs = Set<String>()
        let dedupedItems = items.filter { seenIDs.insert($0.id).inserted }

        var mergedRecords = dedupedItems.map { item in
            var record = RSSArticleRecord(item: item, fetchedAt: fetchedAt, status: articleStatuses[item.id])
            if let oldRecord = existingByID[item.id] {
                // First seen, not last fetched: re-stamping every record made every refresh
                // look like a change and rewrote the whole article file (below).
                record.fetchedAt = oldRecord.fetchedAt
                record.fullText = oldRecord.fullText
                record.fullTextHTML = oldRecord.fullTextHTML
                record.fullTextFetchedAt = oldRecord.fullTextFetchedAt
                record.fullTextIsPartial = oldRecord.fullTextIsPartial

                if articleStatuses[item.id] == nil {
                    record.isRead = oldRecord.isRead
                    record.isFavorite = oldRecord.isFavorite
                    record.lastOpenedAt = oldRecord.lastOpenedAt
                    record.readerScrollY = oldRecord.readerScrollY
                }
            }
            return record
        }
        // 刷新只替换当前分类/查询；缺席的收藏仍可从智能列表打开。
        mergedRecords += existingRecords.filter { record in
            !seenIDs.contains(record.id) && ((record.scope ?? .feed) != scope || append
                || (articleStatuses[record.id]?.isFavorite ?? record.isFavorite))
        }
        if append {
            // 下一页更新已存在条目但不把它搬到最前；追加的新条目保持响应顺序。
            let values = Dictionary(mergedRecords.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            var orderedIDs = Set<String>()
            mergedRecords = (existingRecords.map(\.id) + mergedRecords.map(\.id)).compactMap { id in
                orderedIDs.insert(id).inserted ? values[id] : nil
            }
        }
        let changedScope = mergedRecords.filter { ($0.scope ?? .feed) == scope }
        let previousScope = existingRecords.filter { ($0.scope ?? .feed) == scope }
        if changedScope != previousScope {
            cachedArticlesBySource[sourceID] = mergedRecords
            indexArticles(mergedRecords, replacing: existingRecords, for: sourceID)
            saveRefreshResult(.articles)
        }
        guard hadExistingCache else { return [] }
        return mergedRecords.filter { record in
            existingByID[record.id] == nil && !record.isRead
        }
    }

    @discardableResult
    func applyFeedResponse(_ response: RSSFeedResponse, for sourceID: String,
                           scope: RSSArticleScope = .feed, append: Bool = false) -> [RSSArticleRecord] {
        guard source(id: sourceID) != nil else { return [] }
        switch response {
        case .notModified:
            guard scope == .feed else { return [] }
            var metadata = feedMetadataBySource[sourceID] ?? RSSFeedFetchMetadata()
            metadata.lastFetchedAt = Date()
            feedMetadataBySource[sourceID] = metadata
            saveRefreshResult(.feedMetadata)
            return []

        case .updated(let items, let metadata, let feedInfo):
            if scope == .feed {
                feedMetadataBySource[sourceID] = metadata
                saveRefreshResult(.feedMetadata)
                applyFeedInfo(feedInfo, to: sourceID)
            }
            return mergeFetchedItems(items, for: sourceID, scope: scope, append: append)
        }
    }

    /// 分类/查询列表以持久owner的源顺序展示；空作用域绝不回退为全源缓存。
    func articles(for sourceID: String, scope: RSSArticleScope) -> [RSSArticleRecord] {
        (cachedArticlesBySource[sourceID] ?? []).enumerated().compactMap { index, record in
            guard (record.scope ?? .feed) == scope, articleLocations[record.id]?.index == index else { return nil }
            return record.applying(status: articleStatuses[record.id])
        }
    }

    func articles(for sourceID: String) -> [RSSArticleRecord] {
        (cachedArticlesBySource[sourceID] ?? []).enumerated()
            .compactMap { index, record -> RSSArticleRecord? in
                guard articleLocations[record.id]?.index == index else { return nil }
                return record.applying(status: articleStatuses[record.id])
            }
            .sorted { lhs, rhs in
                (lhs.pubDate ?? lhs.fetchedAt) > (rhs.pubDate ?? rhs.fetchedAt)
            }
    }

    func articles(for smartFeed: RSSSmartFeedKind) -> [RSSArticleRecord] {
        allArticles().filter { article in
            switch smartFeed {
            case .today:
                return Calendar.current.isDateInToday(article.pubDate ?? article.fetchedAt)
            case .allUnread:
                return !article.isRead
            case .starred:
                return article.isFavorite
            }
        }
    }

    func allArticles() -> [RSSArticleRecord] {
        sources
            .flatMap { articles(for: $0.id) }
            .sorted { lhs, rhs in
                (lhs.pubDate ?? lhs.fetchedAt) > (rhs.pubDate ?? rhs.fetchedAt)
            }
    }

    func status(for articleID: String) -> RSSArticleStatus? {
        if let status = articleStatuses[articleID], status.identityVersion == RSSIdentity.version { return status }
        guard let article = article(id: articleID) else { return nil }
        if let status = articleStatuses[article.id] { return status }
        // 早期Fork已经将状态镜像到各源记录；只继承该记录快照，不把歧义raw GUID广播到别的源。
        return RSSArticleStatus(articleId: article.id, sourceID: article.sourceId, identityVersion: RSSIdentity.version, scope: article.scope,
                                isRead: article.isRead, isFavorite: article.isFavorite,
                                lastOpenedAt: article.lastOpenedAt, readerScrollY: article.readerScrollY)
    }

    var firestoreArticleStatusesSnapshot: [RSSArticleStatus] {
        Array(articleStatuses.values)
    }

    func markRead(articleId: String, isRead: Bool) {
        guard let article = article(id: articleId) else { return }
        let articleId = article.id
        var status = self.status(for: articleId) ?? RSSArticleStatus(articleId: articleId)
        guard status.isRead != isRead else { return }
        status.sourceID = article.sourceId
        status.identityVersion = RSSIdentity.version
        status.scope = article.scope
        status.isRead = isRead
        if isRead {
            status.lastOpenedAt = Date()
        }
        articleStatuses[articleId] = status
        updateCachedArticle(articleId: articleId, status: status, previousRead: !isRead)
        save(.statuses)
        if isRead {
            RSSNotificationManager.shared.removeDeliveredNotification(articleID: articleId)
        }
    }

    func updateReaderScrollY(articleId: String, scrollY: Double) {
        guard scrollY.isFinite, let article = article(id: articleId) else { return }
        let articleId = article.id
        var status = self.status(for: articleId) ?? RSSArticleStatus(articleId: articleId)
        let normalizedScrollY = max(0, scrollY)
        guard abs(status.readerScrollY - normalizedScrollY) > 1 else { return }
        status.sourceID = article.sourceId
        status.identityVersion = RSSIdentity.version
        status.scope = article.scope
        status.readerScrollY = normalizedScrollY
        articleStatuses[articleId] = status
        updateCachedArticle(articleId: articleId, status: status)
        save(.statuses)
    }

    func toggleFavorite(articleId: String) {
        guard let article = article(id: articleId) else { return }
        let articleId = article.id
        var status = self.status(for: articleId) ?? RSSArticleStatus(articleId: articleId)
        status.sourceID = article.sourceId
        status.identityVersion = RSSIdentity.version
        status.scope = article.scope
        status.isFavorite.toggle()
        articleStatuses[articleId] = status
        updateCachedArticle(articleId: articleId, status: status)
        save(.statuses)
    }

    func markAllRead(sourceID: String? = nil, isRead: Bool = true) {
        let articles = sourceID.map { self.articles(for: $0) } ?? allArticles()
        markAllRead(articleIDs: articles.map(\.id), isRead: isRead)
    }

    func markAllRead(in folder: RSSFolder, isRead: Bool = true) {
        let ids = sources(in: folder).flatMap { articles(for: $0.id).map(\.id) }
        markAllRead(articleIDs: ids, isRead: isRead)
    }

    func markAllRead(smartFeed: RSSSmartFeedKind, isRead: Bool = true) {
        markAllRead(articleIDs: articles(for: smartFeed).map(\.id), isRead: isRead)
    }

    func markAllRead(articleIDs: [String], isRead: Bool = true) {
        guard !articleIDs.isEmpty else { return }

        let now = Date()
        var changed = false
        for articleID in articleIDs {
            guard let article = article(id: articleID) else { continue }
            let articleID = article.id
            var status = self.status(for: articleID) ?? RSSArticleStatus(articleId: articleID)
            guard status.isRead != isRead else { continue }
            changed = true
            status.sourceID = article.sourceId
            status.identityVersion = RSSIdentity.version
            status.scope = article.scope
            status.isRead = isRead
            if isRead {
                status.lastOpenedAt = now
            }
            articleStatuses[articleID] = status
            updateCachedArticle(articleId: articleID, status: status, previousRead: !isRead)
        }
        guard changed else { return }
        save(.statuses)
        if isRead {
            RSSNotificationManager.shared.removeDeliveredNotifications(articleIDs: articleIDs)
        }
    }

    /// Counted through the status overlay directly. `articles(for:)` copies every article to
    /// apply its status and sorts them; the counts are read in the root view's body (the RSS
    /// badge) and per row of the RSS list, so that was ~7.6 ms per total over 10 000
    /// articles (Debug simulator). Same answer: `applying(status:)` takes `isRead` from the
    /// status when there is one.
    func unreadCount(for sourceID: String) -> Int {
        unreadBySource[sourceID, default: 0]
    }

    private func isRead(_ article: RSSArticleRecord) -> Bool {
        articleStatuses[article.id]?.isRead ?? article.isRead
    }

    func unreadCount(for folder: RSSFolder) -> Int {
        sources(in: folder).reduce(0) { partial, source in
            partial + unreadCount(for: source.id)
        }
    }

    func unreadCount(for smartFeed: RSSSmartFeedKind) -> Int {
        var count = 0
        for source in sources {
            for (index, article) in (cachedArticlesBySource[source.id] ?? []).enumerated()
                where articleLocations[article.id]?.index == index && !isRead(article) {
                switch smartFeed {
                case .today:
                    if Calendar.current.isDateInToday(article.pubDate ?? article.fetchedAt) { count += 1 }
                case .allUnread:
                    count += 1
                case .starred:
                    if articleStatuses[article.id]?.isFavorite ?? article.isFavorite { count += 1 }
                }
            }
        }
        return count
    }

    func totalUnreadCount() -> Int {
        sources.reduce(0) { partial, source in
            partial + unreadCount(for: source.id)
        }
    }

    func lastFetchedAt(for sourceID: String) -> Date? {
        feedMetadataBySource[sourceID]?.lastFetchedAt ?? cachedArticlesBySource[sourceID]?.map(\.fetchedAt).max()
    }

    func feedMetadata(for sourceID: String) -> RSSFeedFetchMetadata? {
        feedMetadataBySource[sourceID]
    }

    /// Drops cached conditional-GET metadata (etag/last-modified) for a source.
    /// Call this when the feed URL changes so the next fetch is unconditional and
    /// a stale validator can't trigger a false `notModified` against the new URL.
    func clearFeedMetadata(for sourceID: String) {
        guard feedMetadataBySource[sourceID] != nil else { return }
        feedMetadataBySource[sourceID] = nil
        save(.feedMetadata)
    }

    func searchArticles(query: String) -> [RSSArticleRecord] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let allArticles = sources.flatMap { articles(for: $0.id) }
        guard !trimmed.isEmpty else {
            return allArticles
        }
        return allArticles.filter { article in
            let sourceName = sources.first(where: { $0.id == article.sourceId })?.name ?? ""
            return article.title.localizedCaseInsensitiveContains(trimmed)
                || article.summary.localizedCaseInsensitiveContains(trimmed)
                || sourceName.localizedCaseInsensitiveContains(trimmed)
                || (article.author?.localizedCaseInsensitiveContains(trimmed) ?? false)
        }
    }

    func article(id articleID: String) -> RSSArticleRecord? {
        let resolvedID: String
        if articleLocations[articleID] != nil { resolvedID = articleID }
        else if let aliases = legacyArticleIDs[articleID], aliases.count == 1, let only = aliases.first { resolvedID = only }
        else { return nil }
        guard let location = articleLocations[resolvedID], source(id: location.sourceID) != nil,
              let records = cachedArticlesBySource[location.sourceID], records.indices.contains(location.index) else { return nil }
        return records[location.index].applying(status: articleStatuses[resolvedID])
    }

    func source(id sourceID: String) -> RSSSource? {
        sources.first { $0.id == sourceID }
    }

    func requestTicket(for sourceID: String) -> RSSRequestTicket? {
        guard source(id: sourceID) != nil else { return nil }
        return .init(sourceID: sourceID, configurationRevision: configurationRevision,
                     authenticationRevision: authenticationRevisions[sourceID, default: 0])
    }

    func accepts(_ ticket: RSSRequestTicket) -> Bool {
        requestTicket(for: ticket.sourceID) == ticket && source(id: ticket.sourceID)?.enabled == true
    }

    func authenticationChanged(for sourceID: String) {
        clearFeedMetadata(for: sourceID)
        authenticationRevisions[sourceID, default: 0] &+= 1
        invalidateRuntimes(for: sourceID)
    }

    func variables(for sourceID: String) -> [String: String] { sourceVariables[sourceID] ?? [:] }

    func runtimeSnapshot(for source: RSSSource) throws -> RSSRuntimeSnapshot {
        guard !unreadableFiles.contains("rss_runtime_variables.json") else { throw ScraperError.runtimeStateUnavailable }
        return .init(variableJSON: sourceOptionJSON[source.id] ?? source.variable, values: variables(for: source.id),
              variableIsStored: sourceOptionJSON[source.id] != nil)
    }

    func mergeRuntimeSnapshot(_ value: RSSRuntimeSnapshot, ticket: RSSRequestTicket, runtime: RSSRuntimeState) -> Bool {
        guard !Task.isCancelled, accepts(ticket), runtime.isCurrent else { return false }
        var files: StoredFiles = []
        if (sourceVariables[ticket.sourceID] ?? [:]) != value.values {
            sourceVariables[ticket.sourceID] = value.values
            files.insert(.variables)
        }
        if value.variableIsStored && sourceOptionJSON[ticket.sourceID] != value.variableJSON {
            sourceOptionJSON[ticket.sourceID] = value.variableJSON
            files.insert(.variables)
        }
        if !files.isEmpty { save(files) }
        return true
    }

    func setVariables(_ values: [String: String], for sourceID: String) {
        guard source(id: sourceID) != nil, (sourceVariables[sourceID] ?? [:]) != values else { return }
        sourceVariables[sourceID] = values
        clearFeedMetadata(for: sourceID)
        configurationRevision &+= 1
        invalidateRuntimes()
        save(.variables)
    }

    func updateFullText(articleId: String, text: String, html: String? = nil, fetchedAt: Date = Date(),
                        isPartial: Bool = false, variables: [String: String]? = nil) {
        guard let existing = article(id: articleId), existing.fullText != text || existing.fullTextHTML != html
                || (existing.fullTextIsPartial ?? false) != isPartial || (variables != nil && existing.variables != variables) else { return }
        let articleId = existing.id
        for sourceID in cachedArticlesBySource.keys {
            guard let index = cachedArticlesBySource[sourceID]?.firstIndex(where: { $0.id == articleId }) else {
                continue
            }
            cachedArticlesBySource[sourceID]?[index].fullText = text
            cachedArticlesBySource[sourceID]?[index].fullTextHTML = html
            cachedArticlesBySource[sourceID]?[index].fullTextFetchedAt = fetchedAt
            cachedArticlesBySource[sourceID]?[index].fullTextIsPartial = isPartial
            if let variables { cachedArticlesBySource[sourceID]?[index].variables = variables }
        }
        save(.articles)
    }

    func updateMediaProgress(articleID: String, attachmentKey: String, position: Double, duration: Double? = nil) {
        guard position.isFinite, position >= 0, let article = article(id: articleID),
              duration == nil || (duration!.isFinite && duration! >= 0) else { return }
        let articleID = article.id
        var status = self.status(for: articleID) ?? RSSArticleStatus(articleId: articleID)
        let key = RSSIdentity.attachment(articleID: articleID, key: attachmentKey)
        let progress = RSSMediaProgress(position: position, duration: duration)
        guard status.mediaProgress?[key] != progress else { return }
        status.sourceID = article.sourceId
        status.identityVersion = RSSIdentity.version
        status.scope = article.scope
        if status.mediaProgress == nil { status.mediaProgress = [:] }
        status.mediaProgress?[key] = progress
        articleStatuses[articleID] = status
        save(.statuses)
    }

    private func updateCachedArticle(articleId: String, status: RSSArticleStatus, previousRead: Bool? = nil) {
        guard let location = articleLocations[articleId],
              let records = cachedArticlesBySource[location.sourceID], records.indices.contains(location.index) else { return }
        let old = records[location.index]
        if let previousRead, previousRead != status.isRead {
            unreadBySource[location.sourceID, default: 0] += status.isRead ? -1 : 1
        }
        cachedArticlesBySource[location.sourceID]?[location.index] = old.applying(status: status)
    }

    private func indexArticles(_ records: [RSSArticleRecord], replacing old: [RSSArticleRecord], for sourceID: String) {
        for record in old {
            articleLocations[record.id] = nil
            if let legacy = record.legacyID {
                legacyArticleIDs[legacy]?.remove(record.id)
                if legacyArticleIDs[legacy]?.isEmpty == true { legacyArticleIDs[legacy] = nil }
            }
        }
        var unread = 0
        for (index, record) in records.enumerated() {
            if articleLocations[record.id] == nil {
                articleLocations[record.id] = (sourceID, index)
                if !isRead(record) { unread += 1 }
            }
            if let legacy = record.legacyID { legacyArticleIDs[legacy, default: []].insert(record.id) }
        }
        unreadBySource[sourceID] = unread
    }

    private func rebuildArticleIndex() {
        articleLocations = [:]
        legacyArticleIDs = [:]
        unreadBySource = [:]
        for (sourceID, records) in cachedArticlesBySource { indexArticles(records, replacing: [], for: sourceID) }
    }

    private func applyFeedInfo(_ feedInfo: RSSFeedInfo?, to sourceID: String) {
        guard let feedInfo,
              let index = sources.firstIndex(where: { $0.id == sourceID }) else {
            return
        }

        var source = sources[index]
        var didChange = false
        let baseURL = URL(string: source.url)

        if let homepageURL = normalizedURLString(feedInfo.homepageURL, relativeTo: baseURL),
           source.homepageURL?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
            source.homepageURL = homepageURL
            didChange = true
        }

        let iconBaseURL = source.homepageURL.flatMap(URL.init(string:)) ?? baseURL
        if let faviconURL = normalizedURLString(feedInfo.faviconURL, relativeTo: iconBaseURL),
           source.faviconURL?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
            source.faviconURL = faviconURL
            didChange = true
        }

        if let title = feedInfo.title?.trimmingCharacters(in: .whitespacesAndNewlines),
           !title.isEmpty,
           shouldReplaceSourceName(source.name, url: source.url) {
            source.name = title
            didChange = true
        }

        if didChange {
            sources[index] = source
            saveRefreshResult(.sources)
        }
    }

    private func normalizedURLString(_ value: String?, relativeTo baseURL: URL?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return nil
        }

        if let url = URL(string: value), url.scheme != nil {
            return url.absoluteString
        }
        return URL(string: value, relativeTo: baseURL)?.absoluteURL.absoluteString
    }

    private func shouldReplaceSourceName(_ name: String, url: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty || trimmed == url
    }

    private func sources(inFolderNamed folderName: String?) -> [RSSSource] {
        let normalizedName = normalizedFolderName(folderName)
        return sources
            .filter { sourceGroup($0.sourceGroup, matches: normalizedName) }
            .sorted { lhs, rhs in
                if lhs.sortOrder == rhs.sortOrder {
                    return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
                }
                return lhs.sortOrder < rhs.sortOrder
            }
    }

    private func normalizedFolderName(_ value: String?) -> String? {
        guard let name = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !name.isEmpty else {
            return nil
        }
        return name
    }

    private func sourceGroup(_ sourceGroup: String?, matches folderName: String?) -> Bool {
        switch (normalizedFolderName(sourceGroup), normalizedFolderName(folderName)) {
        case (nil, nil):
            return true
        case let (lhs?, rhs?):
            return lhs.caseInsensitiveCompare(rhs) == .orderedSame
        default:
            return false
        }
    }

    @discardableResult
    private func ensureFolderExists(named name: String) -> Bool {
        guard let name = normalizedFolderName(name),
              !folders.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) else {
            return false
        }
        folders.append(RSSFolder(name: name, sortOrder: nextFolderSortOrder()))
        return true
    }

    private func nextFolderSortOrder() -> Int {
        (folders.map(\.sortOrder).max() ?? -1) + 1
    }

    private func nextSourceSortOrder(inFolderNamed folderName: String?) -> Int {
        let normalizedName = normalizedFolderName(folderName)
        return (sources
            .filter { normalizedFolderName($0.sourceGroup) == normalizedName }
            .map(\.sortOrder)
            .max() ?? -1) + 1
    }

    private func backfillFoldersFromSources() {
        var didChange = false
        for source in sources {
            guard let groupName = normalizedFolderName(source.sourceGroup) else { continue }
            didChange = ensureFolderExists(named: groupName) || didChange
        }
        if didChange {
            save()
        }
    }

    private func load() {
        sources = load([RSSSource].self, from: sourceStorageURL) ?? []
        folders = load([RSSFolder].self, from: folderStorageURL) ?? []
        cachedArticlesBySource = load([String: [RSSArticleRecord]].self, from: articleStorageURL) ?? [:]
        articleStatuses = load([String: RSSArticleStatus].self, from: statusStorageURL) ?? [:]
        feedMetadataBySource = load([String: RSSFeedFetchMetadata].self, from: feedMetadataStorageURL) ?? [:]
        if let runtime = load(RSSRuntimeStateFile.self, from: sourceStorageURL.deletingLastPathComponent().appendingPathComponent("rss_runtime_variables.json")) {
            sourceVariables = runtime.values
            sourceOptionJSON = runtime.options
        }
        rebuildArticleIndex()
        backfillFoldersFromSources()
    }

    func replaceFromSync(
        sources syncedSources: [RSSSource]?,
        folders syncedFolders: [RSSFolder]?,
        articleStatuses syncedStatuses: [RSSArticleStatus]?
    ) {
        if let syncedSources {
            sources = syncedSources
        }
        if let syncedFolders {
            folders = syncedFolders
        }
        if let syncedStatuses {
            articleStatuses = Dictionary(syncedStatuses.map { ($0.articleId, $0) }, uniquingKeysWith: { first, _ in first })
        }
        rebuildArticleIndex()
        save()
    }

    /// The files `save` writes. Each is one JSON document; the article file holds every
    /// cached article of every feed and is by far the largest.
    struct StoredFiles: OptionSet {
        let rawValue: Int
        static let sources = StoredFiles(rawValue: 1 << 0)
        static let folders = StoredFiles(rawValue: 1 << 1)
        static let articles = StoredFiles(rawValue: 1 << 2)
        static let statuses = StoredFiles(rawValue: 1 << 3)
        static let feedMetadata = StoredFiles(rawValue: 1 << 4)
        static let variables = StoredFiles(rawValue: 1 << 5)
        static let all: StoredFiles = [.sources, .folders, .articles, .statuses, .feedMetadata, .variables]
    }

    /// Runs one refresh of many feeds and writes what it changed once, at the end.
    ///
    /// Each feed's merge used to write all five files, the article file included: 189 feeds
    /// refreshed hourly in the background wrote 1084 MB a day (Crashlytics d88da8b2,
    /// MetricKit disk-write-exception, 2026-10-19). The end write also runs when the refresh
    /// is cancelled — a background task expiring — so nothing merged is lost.
    func performRefreshBatch<T>(_ body: () async -> T) async -> T {
        refreshBatchDepth += 1
        let result = await body()
        refreshBatchDepth -= 1
        if refreshBatchDepth == 0 {
            if !pendingRefreshFiles.isEmpty { save(pendingRefreshFiles) }
            // 写入错误由drainPersistence记录并保留；服务读取persistenceFailed返回失败。
            await persistenceTask?.value
        }
        return result
    }

    private var refreshBatchDepth = 0
    private var pendingRefreshFiles: StoredFiles = []
    /// Writes of each file since launch, for tests.
    private(set) var writeCounts: [String: Int] = [:]

    /// A refresh result's write: deferred to the end of a running `performRefreshBatch`.
    private func saveRefreshResult(_ files: StoredFiles) {
        if refreshBatchDepth > 0 {
            pendingRefreshFiles.formUnion(files)
        } else {
            save(files)
        }
    }

    /// Writes `files` now, together with any refresh result still waiting, so a user's
    /// change in the middle of a refresh is not written ahead of an older state of a file.
    private func save(_ files: StoredFiles = .all) {
        let files = files.union(pendingRefreshFiles)
        pendingRefreshFiles = []
        dirtyFiles.formUnion(files)
        if persistenceTask == nil {
            persistenceTask = Task { await drainPersistence() }
        }
        if !files.isDisjoint(with: [.articles, .statuses]) {
            RSSNotificationManager.shared.updateBadge(unreadCount: totalUnreadCount())
        }
    }

    private var dirtyFiles: StoredFiles = []
    private var failedFiles: StoredFiles = []
    private var unreadableFiles = Set<String>()
    private var persistenceTask: Task<Void, Never>?
    var persistenceFailed: Bool { !failedFiles.isEmpty || !unreadableFiles.isEmpty }

    func backupData() async throws -> Data {
        try await flushPersistence()
        return try await RSSBackupCodec.encode(sources: sources, folders: folders,
                                               records: cachedArticlesBySource, statuses: articleStatuses)
    }

    /// 先完整校验再修改owner；落盘前备份旧文件，失败不会伪报成功或清理可恢复的数据。
    func restoreBackup(_ data: Data) async throws {
        let configuration = configurationRevision
        let content = contentRevision
        let snapshot = try await RSSBackupCodec.decode(data)
        let records = await RSSBackupCodec.materialize(snapshot)
        try Task.checkCancellation()
        try await flushPersistence()
        try await Self.backupBeforeRestore(directory: sourceStorageURL.deletingLastPathComponent())
        guard configuration == configurationRevision, content == contentRevision else {
            throw RSSImportService.Issue.stalePlan
        }
        sources = snapshot.sources
        folders = snapshot.folders
        cachedArticlesBySource = records
        articleStatuses = Dictionary(uniqueKeysWithValues: snapshot.statuses.map { ($0.articleId, $0) })
        feedMetadataBySource = [:]
        sourceVariables = [:]
        sourceOptionJSON = [:]
        authenticationRevisions = [:]
        rebuildArticleIndex()
        save()
        try await flushPersistence()
    }

    private nonisolated static func backupBeforeRestore(directory: URL) async throws {
        let files = ["rss_sources.json", "rss_folders.json", "rss_articles.json", "rss_article_status.json",
                     "rss_feed_metadata.json", "rss_runtime_variables.json"]
        let target = directory.appendingPathComponent("rss-restore-backups", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        for file in files {
            let source = directory.appendingPathComponent(file)
            if FileManager.default.fileExists(atPath: source.path) {
                try FileManager.default.copyItem(at: source, to: target.appendingPathComponent(file))
            }
        }
    }

    func importSnapshot() -> RSSImportService.Snapshot {
        .init(revision: configurationRevision, sources: sources, folders: folders)
    }

    /// 检查比较期间的修改，发布一次，再等待真实落盘；首次抓取不属于此事务。
    func commitImport(_ changes: RSSImportService.Changes) async throws {
        try Task.checkCancellation()
        guard changes.revision == configurationRevision else { throw RSSImportService.Issue.stalePlan }
        guard unreadableFiles.isEmpty else { throw RSSImportService.Issue.persistence }
        if !changes.changedIDs.isEmpty {
            let foldersChanged = folders.count != changes.folders.count
            sources = changes.sources
            if foldersChanged { folders = changes.folders }
            var files: StoredFiles = foldersChanged ? [.sources, .folders] : .sources
            for id in changes.changedIDs where feedMetadataBySource[id] != nil {
                feedMetadataBySource[id] = nil
                files.insert(.feedMetadata)
            }
            save(files)
        }
        try await flushPersistence()
    }

    func flushPersistence() async throws {
        await persistenceTask?.value
        guard !persistenceFailed else { throw RSSImportService.Issue.persistence }
    }

    /// 失败快照不会标成已保存；重试使用当前owner数据而非旧导入快照。
    func retryPersistence() async throws {
        if !failedFiles.isEmpty { save(failedFiles) }
        try await flushPersistence()
    }

    private struct DiskSnapshot: Sendable {
        var sources: [RSSSource]?
        var folders: [RSSFolder]?
        var articles: [String: [RSSArticleRecord]]?
        var statuses: [String: RSSArticleStatus]?
        var metadata: [String: RSSFeedFetchMetadata]?
        var variables: RSSRuntimeStateFile?
        var directory: URL
    }

    private func drainPersistence() async {
        // 场景退出时给已排队的有限写入保留系统后台时间，不在主线程同步等待磁盘。
        let backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "RSS persistence")
        defer {
            if backgroundTask != .invalid { UIApplication.shared.endBackgroundTask(backgroundTask) }
        }
        while !dirtyFiles.isEmpty {
            let files = dirtyFiles.union(failedFiles)
            dirtyFiles = []
            let snapshot = DiskSnapshot(
                sources: files.contains(.sources) ? sources : nil,
                folders: files.contains(.folders) ? folders : nil,
                articles: files.contains(.articles) ? cachedArticlesBySource : nil,
                statuses: files.contains(.statuses) ? articleStatuses : nil,
                metadata: files.contains(.feedMetadata) ? feedMetadataBySource : nil,
                variables: files.contains(.variables) ? RSSRuntimeStateFile(values: sourceVariables, options: sourceOptionJSON) : nil,
                directory: sourceStorageURL.deletingLastPathComponent()
            )
            let results = await Self.write(snapshot, excluding: unreadableFiles)
            failedFiles = []
            for (file, success) in results {
                let kind: StoredFiles
                switch file {
                case "rss_sources.json": kind = .sources
                case "rss_folders.json": kind = .folders
                case "rss_articles.json": kind = .articles
                case "rss_article_status.json": kind = .statuses
                case "rss_runtime_variables.json": kind = .variables
                default: kind = .feedMetadata
                }
                if success { writeCounts[file, default: 0] += 1 } else { failedFiles.insert(kind) }
            }
        }
        persistenceTask = nil
    }

    private nonisolated static func write(_ snapshot: DiskSnapshot, excluding: Set<String>) async -> [(String, Bool)] {
        SourcePerfTrace.span("rss.persist", "main=\(Thread.isMainThread) sources=\(snapshot.sources?.count ?? 0)") {
            var results: [(String, Bool)] = []
            func write<Value: Encodable>(_ value: Value?, _ file: String) {
                guard let value else { return }
                guard !excluding.contains(file) else { results.append((file, false)); return }
                do {
                    let data = try JSONEncoder().encode(value)
                    try FileManager.default.createDirectory(at: snapshot.directory, withIntermediateDirectories: true)
                    try data.write(to: snapshot.directory.appendingPathComponent(file), options: .atomic)
                    results.append((file, true))
                } catch {
                    // 编码错误也可能携带配置内容，只记录固定文件名与错误域/码。
                    let failure = error as NSError
                    AppLogger.info("RSS persistence failed", context: ["file": file, "domain": failure.domain, "code": failure.code], level: .error)
                    results.append((file, false))
                }
            }
            write(snapshot.sources, "rss_sources.json")
            write(snapshot.folders, "rss_folders.json")
            write(snapshot.articles, "rss_articles.json")
            write(snapshot.statuses, "rss_article_status.json")
            write(snapshot.metadata, "rss_feed_metadata.json")
            write(snapshot.variables, "rss_runtime_variables.json")
            return results
        }
    }

    private func load<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            let value = try JSONDecoder().decode(type, from: Data(contentsOf: url))
            if let configs = value as? [RSSSource], configs.contains(where: { $0.configurationVersion != nil && $0.configurationVersion != 1 }) {
                throw RSSBackupCodec.Failure.unsupportedVersion
            }
            return value
        } catch {
            unreadableFiles.insert(url.lastPathComponent)
            let failure = error as NSError
            AppLogger.info("RSS storage could not be read", context: ["file": url.lastPathComponent, "domain": failure.domain, "code": failure.code], level: .error)
            return nil
        }
    }
}
