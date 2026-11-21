import Foundation

struct RuleSubscriptionUpdatePlan: Sendable {
    let count: Int
    struct Entry: Identifiable, Sendable {
        let id: UUID
        let title: String
    }
    let entries: [Entry]
    var authorVersions: [String: Int64]
    var replacementIDs: [String: String]
    let apply: @MainActor @Sendable (@escaping @MainActor @Sendable () throws -> Void) async throws -> Void
    init(count: Int, titles: [String], authorVersions: [String: Int64] = [:], replacementIDs: [String: String] = [:],
         apply: @escaping @MainActor @Sendable (@escaping @MainActor @Sendable () throws -> Void) async throws -> Void) {
        self.count = count
        entries = titles.map { Entry(id: UUID(), title: $0) }
        self.authorVersions = authorVersions; self.replacementIDs = replacementIDs; self.apply = apply
    }

    @concurrent static func make(count: Int, titles: [String], authorVersions: [String: Int64] = [:], replacementIDs: [String: String] = [:],
         apply: @escaping @MainActor @Sendable (@escaping @MainActor @Sendable () throws -> Void) async throws -> Void) async -> Self {
        SourcePerfTrace.span("rule.subscription.preview", "main=\(Thread.isMainThread) entries=\(count)") {
            Self(count: count, titles: titles, authorVersions: authorVersions, replacementIDs: replacementIDs, apply: apply)
        }
    }
}

/// 只编排配置包的比较和提交；HTTP、JSON导入及数据写入仍属于现有实现。
enum RuleSubscriptionUpdateService {
    typealias Fetch = @Sendable (URL, Int) async throws -> Data
    typealias Prepare = @MainActor @Sendable (RuleSubscription, Data) async throws -> RuleSubscriptionUpdatePlan

    static let maximumBytes = 8 * 1_024 * 1_024
    static let fetch: Fetch = { url, limit in
        try await SourceDiagnosticContext.$restrictedTask.withValue(true) {
            try await RSSImportService.download(url, maximumBytes: limit,
                withoutUserAgent: url.absoluteString.hasSuffix("#requestWithoutUA"))
        }
    }
    static let prepare: Prepare = { subscription, bytes in
        switch subscription.type {
        case .bookSources: return try await books(subscription, bytes: bytes, store: .shared)
        case .rssSources: return try await rss(subscription, bytes: bytes, store: .shared)
        case .replaceRules: return try await replacements(subscription, bytes: bytes, store: .shared)
        }
    }

    @MainActor static func books(_ subscription: RuleSubscription, bytes: Data, store: BookSourceStore) async throws -> RuleSubscriptionUpdatePlan {
        await store.waitUntilLoaded()
        let revision = store.mutationRevision
        let existing = store.sources
        let result = try await compareBooks(subscription, bytes: bytes, existing: existing)
        return await RuleSubscriptionUpdatePlan.make(count: result.sources.count, titles: result.titles,
            authorVersions: result.versions, apply: { authorize in
                try await store.commitSubscriptionSources(result.sources, expectedRevision: revision, authorize: authorize)
            })
    }

    private struct BookChanges: Sendable {
        var sources: [BookSource]
        var titles: [String]
        var versions: [String: Int64]
    }
    @concurrent private static func compareBooks(_ subscription: RuleSubscription, bytes: Data, existing: [BookSource]) async throws -> BookChanges {
        guard bytes.count <= maximumBytes, let text = String(data: bytes, encoding: .utf8),
              let incoming = BookSourceStore.parseSources(text), incoming.count <= 10_000,
              incoming.allSatisfy({ !$0.bookSourceUrl.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else { throw RuleSubscriptionFailure.invalidPack }
        let locals = Dictionary(grouping: existing, by: \.bookSourceUrl)
        var versions = subscription.authorVersions ?? [:]
        var selected: [BookSource] = []
        var latest: [String: BookSource] = [:]
        var order: [String] = []
        for source in incoming {
            if latest[source.bookSourceUrl] == nil { order.append(source.bookSourceUrl) }
            latest[source.bookSourceUrl] = source
        }
        for key in order {
            guard let source = latest[key] else { continue }
            let accepted = subscription.authorVersions?[key]
            versions[key] = max(versions[key] ?? 0, source.lastUpdateTime)
            if let accepted, accepted > 0, source.lastUpdateTime > 0, source.lastUpdateTime <= accepted { continue }
            guard let matches = locals[key] else { selected.append(source); continue }
            guard matches.count == 1, let old = matches.first else { throw RuleSubscriptionFailure.stale }
            var candidate = BookSourceImportOptions(keepName: true, keepGroup: true, keepEnable: true, keepCustomOrder: true).merged(incoming: source, local: old)
            candidate.id = old.id
            if !candidate.hasSameContent(as: old) { selected.append(candidate) }
        }
        return BookChanges(sources: selected, titles: selected.map { String($0.bookSourceName.prefix(256)) }, versions: versions)
    }

    @MainActor static func rss(_ subscription: RuleSubscription, bytes: Data, store: RSSStore) async throws -> RuleSubscriptionUpdatePlan {
        let loaded = try await RSSImportService.load(.data(bytes))
        let plan = try await RSSImportService.compare(loaded, with: store.importSnapshot())
        guard plan.errors == 0, plan.rows.count <= 10_000 else { throw RuleSubscriptionFailure.invalidPack }
        let selection = try await selectRSS(subscription, rows: plan.rows)
        let changes = try await RSSImportService.changes(for: plan, selected: selection.ids)
        return await RuleSubscriptionUpdatePlan.make(count: selection.ids.count, titles: selection.titles, authorVersions: selection.versions, apply: { authorize in
            try authorize()
            try await store.commitImport(changes)
        })
    }

    private struct RSSSelection: Sendable {
        var ids: Set<UUID> = []
        var titles: [String] = []
        var versions: [String: Int64]
    }
    @concurrent private static func selectRSS(_ subscription: RuleSubscription, rows: [RSSImportService.Row]) async throws -> RSSSelection {
        var result = RSSSelection(versions: subscription.authorVersions ?? [:])
        for row in rows {
            guard let source = row.source else { throw RuleSubscriptionFailure.invalidPack }
            let key = source.sourceKey
            let clock = source.lastUpdateTime
            guard clock.isFinite, clock > Double(Int64.min), clock < Double(Int64.max) else { throw RuleSubscriptionFailure.invalidPack }
            let remote = Int64(clock)
            let accepted = subscription.authorVersions?[key]
            result.versions[key] = max(result.versions[key] ?? 0, remote)
            if let accepted, accepted > 0, remote > 0, remote <= accepted { continue }
            if row.disposition.selectable { result.ids.insert(row.id); result.titles.append(String(source.name.prefix(256))) }
        }
        return result
    }

    @MainActor static func replacements(_ subscription: RuleSubscription, bytes: Data, store: ReplaceRuleStore) async throws -> RuleSubscriptionUpdatePlan {
        let revision = store.revision
        let result = try await compareReplacements(subscription, bytes: bytes, existing: store.rules)
        return await RuleSubscriptionUpdatePlan.make(count: result.count, titles: result.titles, replacementIDs: result.ids, apply: { authorize in
            try authorize()
            try await store.commitSubscriptionRules(result.rules, expectedRevision: revision, changed: result.count > 0)
        })
    }

    struct ReplacementChanges: Sendable {
        var rules: [ReplaceRule]
        var count: Int
        var titles: [String]
        var ids: [String: String]
    }
    @concurrent static func compareReplacements(_ subscription: RuleSubscription, bytes: Data, existing: [ReplaceRule]) async throws -> ReplacementChanges {
        guard bytes.count <= maximumBytes else { throw RuleSubscriptionFailure.tooLarge }
        let raw = try JSONSerialization.jsonObject(with: bytes)
        let objects: [[String: Any]]
        if let array = raw as? [[String: Any]] { objects = array }
        else if let object = raw as? [String: Any] { objects = [object] }
        else { throw RuleSubscriptionFailure.invalidPack }
        guard objects.count <= 10_000 else { throw RuleSubscriptionFailure.tooLarge }
        // 当前替换语义尚未全面对齐：不能静默丢弃标题规则或排除范围后提示订阅成功。
        func boolean(_ value: Any?, default fallback: Bool) -> Bool {
            if let value = value as? Bool { return value }
            if let value = value as? String { return value.lowercased() == "true" || value == "1" }
            return fallback
        }
        guard objects.allSatisfy({ boolean($0["scopeContent"], default: true)
            && !boolean($0["scopeTitle"], default: false) && !boolean($0["scopeSource"], default: false)
            && ($0["excludeScope"] as? String ?? "").isEmpty
            && ($0["timeoutMillisecond"] == nil || $0["timeoutMillisecond"] is NSNull
                || ($0["timeoutMillisecond"] as? NSNumber)?.doubleValue == 3000 || $0["timeoutMillisecond"] as? String == "3000")
        }) else { throw RuleSubscriptionFailure.unsupportedPack }
        let incoming = objects.isEmpty ? [] : try ReplaceRuleImportParser.parse(data: bytes)
        guard incoming.count == objects.count, Set(incoming.map(\.id)).count == incoming.count,
              objects.allSatisfy({ object in
                  if let number = object["id"] as? NSNumber { return Int64(number.stringValue) != nil }
                  if let id = object["id"] as? String { return Int64(id) != nil || UUID(uuidString: id) != nil }
                  return false
              }) else { throw RuleSubscriptionFailure.invalidPack }
        var ids = subscription.replacementIDs ?? [:]
        var selected: [ReplaceRule] = []
        for var rule in incoming {
            let remoteID = rule.id
            let local = existing.first { $0.id == (ids[remoteID] ?? remoteID) }
                ?? existing.first { $0.pattern == rule.pattern && $0.replacement == rule.replacement && $0.scope == rule.scope }
            if let local {
                rule.id = local.id; rule.sortOrder = local.sortOrder
                rule.enabled = local.enabled; rule.name = local.name
            }
            if remoteID.hasPrefix("legado:") { ids[remoteID] = rule.id }
            if local == nil || rule != local { selected.append(rule) }
        }
        return ReplacementChanges(rules: ReplaceRuleStore.merging(selected, into: existing), count: selected.count,
            titles: selected.map { String($0.name.prefix(256)) }, ids: ids)
    }
}
