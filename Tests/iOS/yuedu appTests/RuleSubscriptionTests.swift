import Foundation
import Testing
@testable import yuedu_app

@Suite("规则包订阅闭环", .serialized, .timeLimit(.minutes(2)))
@MainActor
struct RuleSubscriptionTests {
    private func directory() throws -> URL {
        let value = FileManager.default.temporaryDirectory.appendingPathComponent("RuleSubscriptionTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: value, withIntermediateDirectories: true)
        return value
    }
    private func clean(_ root: URL) {
        do { try FileManager.default.removeItem(at: root) }
        catch { Issue.record("测试目录清理失败") }
    }
    private func pack(version: Int = 10, content: String = "article") -> Data {
        Data("[{\"bookSourceUrl\":\"https://book.example.invalid\",\"bookSourceName\":\"远端名称\",\"lastUpdateTime\":\(version),\"ruleSearch\":{\"bookList\":\"\(content)\"}}]".utf8)
    }

    @Test("到期检查使用小时且系统时钟回退不会永久阻挡")
    func dueTime() {
        var value = RuleSubscription(name: "合成包", url: "https://example.invalid/pack.json")
        value.update = 10_000; value.updateInterval = 1
        #expect(!value.isDue(at: Date(timeIntervalSince1970: 3_609)))
        #expect(value.isDue(at: Date(timeIntervalSince1970: 3_610)))
        #expect(value.isDue(at: Date(timeIntervalSince1970: 1)))
    }

    @Test("保存和重载完整且同内容保存不写盘")
    func persistenceAndNoOp() async throws {
        let root = try directory(); defer { clean(root) }
        let file = root.appendingPathComponent("subscriptions.json")
        let store = RuleSubscriptionStore(file: file)
        var value = RuleSubscription(name: "合成包", url: "https://example.invalid/pack.json")
        value.js = "不执行的元数据"; value.showRule = "保留显示规则"; value.sourceUrl = "源身份"
        try await store.upsert(value)
        let bytes = try Data(contentsOf: file)
        let writes = store.writeCount
        try await store.upsert(value)
        #expect(store.writeCount == writes)
        #expect(try Data(contentsOf: file) == bytes)
        let reloaded = RuleSubscriptionStore(file: file)
        try await reloaded.load()
        #expect(reloaded.subscriptions == [value])
    }

    @Test("手动确认前不改书源，确认后保留本地身份和设置")
    func manualBookUpdate() async throws {
        let root = try directory(); defer { clean(root) }
        let sources = BookSourceStore(directory: root.appendingPathComponent("sources"))
        await sources.waitUntilLoaded()
        var original = BookSource(bookSourceUrl: "https://book.example.invalid", bookSourceName: "本地名称")
        original.bookSourceGroup = "本地组"; original.enabled = false; original.ruleSearch.bookList = "old"
        try sources.importSelected([original], options: .direct)
        try await sources.persistPendingChanges()
        let fixture = SubscriptionBytes(pack())
        let store = RuleSubscriptionStore(file: root.appendingPathComponent("subscriptions.json"), fetch: { _, _ in await fixture.read() },
            prepare: { value, bytes in try await RuleSubscriptionUpdateService.books(value, bytes: bytes, store: sources) })
        let value = RuleSubscription(name: "合成包", url: "https://example.invalid/pack.json")
        try await store.upsert(value)
        await store.check(value.id, now: Date(timeIntervalSince1970: 100))
        #expect(store.outcomes[value.id] == .pending(1))
        #expect(sources.source(id: original.id)?.ruleSearch.bookList == "old")
        #expect(store.subscriptions.first?.lastSuccessfulCheck == nil)
        await store.confirm(value.id, now: Date(timeIntervalSince1970: 101))
        #expect(store.outcomes[value.id] == .updated(1))
        let updated = try #require(sources.source(id: original.id))
        #expect(updated.bookSourceName == "本地名称" && updated.bookSourceGroup == "本地组" && !updated.enabled)
        #expect(updated.ruleSearch.bookList == "article")
        let revision = sources.mutationRevision
        await fixture.set(pack(version: 9, content: "older"))
        await store.check(value.id, now: Date(timeIntervalSince1970: 102))
        #expect(store.outcomes[value.id] == .upToDate)
        #expect(sources.mutationRevision == revision)
        #expect(sources.source(id: original.id)?.ruleSearch.bookList == "article")
        let reloaded = BookSourceStore(directory: root.appendingPathComponent("sources"))
        await reloaded.waitUntilLoaded()
        #expect(reloaded.source(id: original.id)?.ruleSearch.bookList == "article")
    }

    @Test("静默更新自动提交，旧本地时钟不阻挡远端作者版本")
    func silentBookUpdate() async throws {
        let root = try directory(); defer { clean(root) }
        let sources = BookSourceStore(directory: root.appendingPathComponent("sources")); await sources.waitUntilLoaded()
        let data = pack()
        let store = RuleSubscriptionStore(file: root.appendingPathComponent("subscriptions.json"), fetch: { _, _ in data },
            prepare: { value, bytes in try await RuleSubscriptionUpdateService.books(value, bytes: bytes, store: sources) })
        var value = RuleSubscription(name: "合成包", url: "https://example.invalid/pack.json"); value.silentUpdate = true
        try await store.upsert(value)
        await store.check(value.id)
        #expect(store.outcomes[value.id] == .updated(1))
        #expect(store.pending[value.id] == nil && sources.sources.count == 1)
        #expect(store.subscriptions.first?.lastSuccessfulCheck != nil)
    }

    @Test("网络失败只更新尝试时间，不伪造成功或触及书源")
    func failureDoesNotAdvanceSuccess() async throws {
        let root = try directory(); defer { clean(root) }
        let store = RuleSubscriptionStore(file: root.appendingPathComponent("subscriptions.json"), fetch: { _, _ in throw URLError(.notConnectedToInternet) })
        var value = RuleSubscription(name: "合成包", url: "https://example.invalid/pack.json"); value.lastSuccessfulCheck = 1_000
        try await store.upsert(value)
        await store.check(value.id, now: Date(timeIntervalSince1970: 5))
        #expect(store.subscriptions.first?.update == 5_000)
        #expect(store.subscriptions.first?.lastSuccessfulCheck == 1_000)
        guard case .failed = store.outcomes[value.id] else { Issue.record("必须显示失败"); return }
    }

    @Test("删除或改地址后晚到的配置包不复活订阅或导入来源", arguments: [false, true])
    func staleNetworkDoesNotApply(changesURL: Bool) async throws {
        let root = try directory(); defer { clean(root) }
        let sources = BookSourceStore(directory: root.appendingPathComponent("sources")); await sources.waitUntilLoaded()
        let latch = SubscriptionLatch()
        let store = RuleSubscriptionStore(file: root.appendingPathComponent("subscriptions.json"), fetch: { _, _ in await latch.read() },
            prepare: { value, bytes in try await RuleSubscriptionUpdateService.books(value, bytes: bytes, store: sources) })
        var value = RuleSubscription(name: "合成包", url: "https://example.invalid/pack.json"); value.silentUpdate = true
        try await store.upsert(value)
        let task = Task { await store.check(value.id) }
        await latch.waitUntilStarted()
        if changesURL {
            value.url = "https://example.invalid/new.json"
            try await store.upsert(value)
        } else { try await store.delete(value.id) }
        await latch.release(pack())
        await task.value
        #expect(sources.sources.isEmpty)
        #expect(store.pending[value.id] == nil)
        #expect(changesURL ? store.subscriptions.first?.url == value.url : store.subscriptions.isEmpty)
    }

    @Test("确认期间本地来源已改变，旧比较结果不能覆盖新配置")
    func staleLocalPreview() async throws {
        let root = try directory(); defer { clean(root) }
        let sources = BookSourceStore(directory: root.appendingPathComponent("sources")); await sources.waitUntilLoaded()
        let data = pack()
        let store = RuleSubscriptionStore(file: root.appendingPathComponent("subscriptions.json"), fetch: { _, _ in data },
            prepare: { value, bytes in try await RuleSubscriptionUpdateService.books(value, bytes: bytes, store: sources) })
        let value = RuleSubscription(name: "合成包", url: "https://example.invalid/pack.json")
        try await store.upsert(value); await store.check(value.id)
        try sources.importSelected([BookSource(bookSourceUrl: "https://other.example.invalid", bookSourceName: "用户新增")], options: .direct)
        try await sources.persistPendingChanges()
        await store.confirm(value.id)
        #expect(sources.sources.count == 1 && sources.sources.first?.bookSourceName == "用户新增")
        guard case .failed = store.outcomes[value.id] else { Issue.record("旧预览应被拒绝"); return }
    }

    @Test("RSS更新保留本地源ID、分组和启用状态，不自动刷新文章")
    func rssUpdate() async throws {
        let root = try directory(); defer { clean(root) }
        let rss = RSSStore(storageDirectory: root.appendingPathComponent("rss"))
        let oldData = Data(#"{"sourceUrl":"https://rss.example.invalid","sourceName":"本地RSS","sourceGroup":"本地组","enabled":false,"ruleArticles":"old"}"#.utf8)
        let original = try #require(LegadoSourceJSONParser.parse(data: oldData).first)
        rss.addSource(original); try await rss.flushPersistence()
        let data = Data(#"[{"sourceUrl":"https://rss.example.invalid","sourceName":"远端RSS","ruleArticles":"article","lastUpdateTime":100}]"#.utf8)
        let store = RuleSubscriptionStore(file: root.appendingPathComponent("subscriptions.json"), fetch: { _, _ in data },
            prepare: { value, bytes in try await RuleSubscriptionUpdateService.rss(value, bytes: bytes, store: rss) })
        var value = RuleSubscription(name: "RSS包", url: "https://example.invalid/rss.json"); value.type = .rssSources; value.silentUpdate = true
        try await store.upsert(value); await store.check(value.id)
        #expect(store.outcomes[value.id] == .updated(1))
        let updated = try #require(rss.source(id: original.id))
        #expect(updated.name == "本地RSS" && updated.sourceGroup == "本地组" && !updated.enabled)
        #expect(updated.ruleArticles == "article")
        let writes = rss.writeCounts
        await store.check(value.id)
        #expect(rss.writeCounts == writes)
        try await rss.flushPersistence()
    }

    @Test("替换规则数字ID更新保留本地身份，没有重复规则")
    func replacementIdentity() async throws {
        let old = ReplaceRule(id: "old-local", name: "规则", pattern: "old", replacement: "A")
        let value = RuleSubscription(name: "替换包", url: "https://example.invalid/replace.json")
        let first = try await RuleSubscriptionUpdateService.compareReplacements(value,
            bytes: Data(#"[{"id":42,"name":"规则","pattern":"old","replacement":"A"}]"#.utf8), existing: [old])
        #expect(first.count == 0 && first.ids["legado:42"] == "old-local")
        var accepted = value; accepted.replacementIDs = first.ids
        let next = try await RuleSubscriptionUpdateService.compareReplacements(accepted,
            bytes: Data(#"[{"id":42,"name":"规则","pattern":"new","replacement":"B"}]"#.utf8), existing: first.rules)
        #expect(next.count == 1 && next.rules.count == 1)
        #expect(next.rules.first?.id == "old-local" && next.rules.first?.pattern == "new")
    }

    @Test("未支持的替换作用域必须明确失败而不是丢字段成功", arguments: [#"{"scopeTitle":true}"#, #"{"scopeContent":"false"}"#, #"{"excludeScope":"书名"}"#])
    func unsupportedReplacement(fields: String) async throws {
        let extra = String(fields.dropFirst().dropLast())
        let bytes = Data(("[{\"id\":1,\"name\":\"规则\",\"pattern\":\"x\"," + extra + "}]").utf8)
        await #expect(throws: RuleSubscriptionFailure.self) {
            _ = try await RuleSubscriptionUpdateService.compareReplacements(RuleSubscription(name: "包", url: "https://example.invalid/rules.json"), bytes: bytes, existing: [])
        }
    }

    @Test("订阅不允许把非标准布尔值当作关闭标题作用域")
    func replacementSubscriptionRejectsNonBooleanScope() async {
        let bytes = Data(#"[{"id":1,"pattern":"正文"},{"id":2,"pattern":"标题","scopeTitle":"sometimes"}]"#.utf8)
        await #expect(throws: RuleSubscriptionFailure.self) {
            _ = try await RuleSubscriptionUpdateService.compareReplacements(
                RuleSubscription(name: "替换包", url: "https://example.invalid/rules.json"), bytes: bytes, existing: []
            )
        }
    }

    @Test("同一混合包从订阅入口整包拒绝，不改磁盘上的现有规则")
    func mixedReplacementSubscriptionDoesNotWrite() async throws {
        let root = try directory(); defer { clean(root) }
        let file = root.appendingPathComponent("replace.json")
        let rules = ReplaceRuleStore(file: file)
        rules.add(ReplaceRule(id: "legado:42", name: "本地正文", pattern: "原样"))
        try await rules.persistPendingChanges()
        let before = try Data(contentsOf: file)
        let revision = rules.revision

        let store = RuleSubscriptionStore(file: root.appendingPathComponent("subscriptions.json"),
            fetch: { _, _ in MixedReplaceRuleFixture.data },
            prepare: { value, bytes in try await RuleSubscriptionUpdateService.replacements(value, bytes: bytes, store: rules) })
        var value = RuleSubscription(name: "替换包", url: "https://example.invalid/replace.json")
        value.type = .replaceRules
        value.silentUpdate = true
        try await store.upsert(value)
        await store.check(value.id)
        #expect(store.outcomes[value.id] == .failed(RuleSubscriptionFailure.invalidPack.localizedDescription))
        #expect(store.subscriptions.first?.lastSuccessfulCheck == nil)
        #expect(rules.revision == revision)
        #expect(try Data(contentsOf: file) == before)
    }

    @Test("订阅保留非空替换别名，规则在原始地址列表中的每个源生效", arguments: [
        [""],
        ["https://news.example.invalid/feed?editions=morning,evening;late#day"],
        ["https://a.example.invalid/feed", "https://b.example.invalid/feed"],
        ["https://a.example.invalid/feed?editions=morning,evening", "https://b.example.invalid/feed"],
        ["https://a.invalid/?v=x,", "https://b.invalid/feed"],
        ["https://a.invalid/?q=x,http://"],
        ["https://a.invalid/?q=x,http://", "https://b.invalid/feed"]
    ])
    func replacementSubscriptionPreservesAliasAndScope(targets: [String]) async throws {
        let root = try directory(); defer { clean(root) }
        let rules = ReplaceRuleStore(file: root.appendingPathComponent("replace.json"))
        let scope = targets.joined(separator: targets.first?.contains(",") == true ? ";" : ",\n")
        let bytes = try JSONSerialization.data(withJSONObject: [
            ["id": 42, "pattern": "A", "replacement": "", "replace": "B", "scope": scope]
        ])
        let store = RuleSubscriptionStore(file: root.appendingPathComponent("subscriptions.json"), fetch: { _, _ in bytes },
            prepare: { value, bytes in try await RuleSubscriptionUpdateService.replacements(value, bytes: bytes, store: rules) })
        var value = RuleSubscription(name: "替换包", url: "https://example.invalid/replace.json")
        value.type = .replaceRules
        value.silentUpdate = true

        try await store.upsert(value)
        await store.check(value.id)
        #expect(store.outcomes[value.id] == .updated(1))
        #expect(rules.rules.map(\.scope) == [scope.isEmpty ? "global" : scope])
        for target in targets {
            let applicable = ReplaceRuleStore.rules(for: target, from: rules.rules)
            #expect(ReplaceRuleEngine.apply(applicable, to: "A") == "B")
        }
        if !scope.isEmpty {
            for target in ["https://unrelated.example.invalid", "https://a.invalid/?v=x", "https://a.invalid/?q=x"] {
                let other = ReplaceRuleStore.rules(for: target, from: rules.rules)
                #expect(ReplaceRuleEngine.apply(other, to: "A") == "A")
            }
        }
    }

    @Test("订阅整包拒绝坏行或多个外层候选，既有同 ID 规则不变", arguments: [
        #"[{"id":42,"pattern":"(","isRegex":true}]"#,
        #"[{"id":42,"pattern":"A","replacement":"B"},null]"#,
        #"{"rules":[],"data":[{"id":42,"pattern":"("}]}"#,
        #"{"data":[{"id":42,"pattern":"("}],"rules":[{"id":42,"pattern":"A","replacement":"B"}]}"#,
        #"{"id":42,"pattern":"A","replacement":"B","rules":[],"data":[]}"#,
        #"[{"id":42,"pattern":"A","replacement":"B","rules":[],"data":[]}]"#,
        #"{"data":[{"id":42,"pattern":"A","replacement":"B","rules":[],"data":[]}]}"#,
        #"[{"id":42,"pattern":"A","replacement":"B"},{"id":43,"pattern":"C","data":null}]"#
    ])
    func replacementSubscriptionRejectsInvalidRows(json: String) async throws {
        let root = try directory(); defer { clean(root) }
        let file = root.appendingPathComponent("replace.json")
        let rules = ReplaceRuleStore(file: file)
        rules.add(ReplaceRule(id: "legado:42", name: "有效规则", pattern: "A", replacement: "旧"))
        try await rules.persistPendingChanges()
        let before = try Data(contentsOf: file)
        let revision = rules.revision
        let store = RuleSubscriptionStore(file: root.appendingPathComponent("subscriptions.json"), fetch: { _, _ in Data(json.utf8) },
            prepare: { value, bytes in try await RuleSubscriptionUpdateService.replacements(value, bytes: bytes, store: rules) })
        var value = RuleSubscription(name: "替换包", url: "https://example.invalid/replace.json")
        value.type = .replaceRules
        value.silentUpdate = true

        value.lastSuccessfulCheck = 111_000
        try await store.upsert(value)
        await store.check(value.id, now: Date(timeIntervalSince1970: 222))
        #expect(store.outcomes[value.id] == .failed(RuleSubscriptionFailure.invalidPack.localizedDescription))
        #expect(store.subscriptions.first?.lastSuccessfulCheck == 111_000)
        #expect(rules.revision == revision)
        #expect(try Data(contentsOf: file) == before)
        #expect(ReplaceRuleEngine.apply(rules.rules, to: "A") == "旧")
    }

    @Test("替换规则确认后实际落盘，重复检查不写，更新保留本地开关和名称")
    func replacementPersistence() async throws {
        let root = try directory(); defer { clean(root) }
        let file = root.appendingPathComponent("replace.json")
        let rules = ReplaceRuleStore(file: file)
        let fixture = SubscriptionBytes(Data(#"[{"id":42,"name":"规则","pattern":"first","replacement":"A"}]"#.utf8))
        let store = RuleSubscriptionStore(file: root.appendingPathComponent("subscriptions.json"), fetch: { _, _ in await fixture.read() },
            prepare: { value, bytes in try await RuleSubscriptionUpdateService.replacements(value, bytes: bytes, store: rules) })
        var value = RuleSubscription(name: "替换包", url: "https://example.invalid/replace.json"); value.type = .replaceRules
        try await store.upsert(value); await store.check(value.id)
        #expect(rules.rules.isEmpty && store.outcomes[value.id] == .pending(1))
        await store.confirm(value.id)
        #expect(store.outcomes[value.id] == .updated(1))
        let bytes = try Data(contentsOf: file)
        #expect(try JSONDecoder().decode([ReplaceRule].self, from: bytes) == rules.rules)
        await store.check(value.id)
        let unchanged = try Data(contentsOf: file)
        #expect(store.outcomes[value.id] == .upToDate && unchanged == bytes)
        var local = try #require(rules.rules.first); local.enabled = false; local.name = "本地名称"
        rules.update(local); try await rules.persistPendingChanges()
        await fixture.set(Data(#"{"data":[{"id":42,"name":"远端名称","pattern":"next","replacement":"B"}]}"#.utf8))
        await store.check(value.id); await store.confirm(value.id)
        #expect(rules.rules.count == 1 && rules.rules.first?.id == local.id)
        #expect(rules.rules.first?.enabled == false && rules.rules.first?.name == "本地名称")
        #expect(rules.rules.first?.pattern == "next")
        let reloaded = ReplaceRuleStore(file: file); reloaded.reloadFromDisk()
        #expect(reloaded.rules == rules.rules)
    }

    @Test("目标规则写入失败不标记成功，恢复路径后无变化检查仍重试最新快照")
    func replacementWriteFailureRetry() async throws {
        let root = try directory(); defer { clean(root) }
        let blocked = root.appendingPathComponent("blocked")
        try Data("测试阻挡文件".utf8).write(to: blocked)
        let file = blocked.appendingPathComponent("replace.json")
        let rules = ReplaceRuleStore(file: file)
        let data = Data(#"[{"id":42,"name":"规则","pattern":"next","replacement":"B"}]"#.utf8)
        let store = RuleSubscriptionStore(file: root.appendingPathComponent("subscriptions.json"), fetch: { _, _ in data },
            prepare: { value, bytes in try await RuleSubscriptionUpdateService.replacements(value, bytes: bytes, store: rules) })
        var value = RuleSubscription(name: "替换包", url: "https://example.invalid/replace.json"); value.type = .replaceRules; value.silentUpdate = true
        try await store.upsert(value); await store.check(value.id)
        guard case .failed = store.outcomes[value.id] else { Issue.record("写入失败不能提示更新成功"); return }
        #expect(store.subscriptions.first?.lastSuccessfulCheck == nil)
        try FileManager.default.moveItem(at: blocked, to: root.appendingPathComponent("preserved-blocker"))
        try FileManager.default.createDirectory(at: blocked, withIntermediateDirectories: true)
        await store.check(value.id)
        #expect(store.outcomes[value.id] == .upToDate && store.subscriptions.first?.lastSuccessfulCheck != nil)
        #expect(try JSONDecoder().decode([ReplaceRule].self, from: Data(contentsOf: file)) == rules.rules)
    }

    @Test("前台激活只检查一次到期项，重复通知不发重复请求")
    func foregroundDueChecks() async throws {
        let root = try directory(); defer { clean(root) }
        let fixture = SubscriptionBytes(Data("[]".utf8))
        let store = RuleSubscriptionStore(file: root.appendingPathComponent("subscriptions.json"), fetch: { _, _ in await fixture.read() },
            prepare: { _, _ in RuleSubscriptionUpdatePlan(count: 0, titles: [], apply: { authorize in try authorize() }) })
        var value = RuleSubscription(name: "合成包", url: "https://example.invalid/pack.json"); value.autoUpdate = true
        try await store.upsert(value)
        store.setActive(true); await store.waitForForegroundWork()
        store.setActive(true); await store.waitForForegroundWork()
        store.setActive(false); store.setActive(true); await store.waitForForegroundWork(); store.setActive(false)
        #expect(await fixture.count == 1)
        #expect(store.outcomes[value.id] == .upToDate)
    }

    @Test("未来版本和写入错误不覆写原文件或假装保存")
    func storageFailure() async throws {
        let root = try directory(); defer { clean(root) }
        let future = root.appendingPathComponent("future.json")
        let bytes = Data(#"{"format":99,"subscriptions":[]}"#.utf8); try bytes.write(to: future)
        let futureStore = RuleSubscriptionStore(file: future)
        await #expect(throws: RuleSubscriptionFailure.self) { try await futureStore.load() }
        #expect(try Data(contentsOf: future) == bytes)
        let blocked = root.appendingPathComponent("blocked"); try bytes.write(to: blocked)
        let store = RuleSubscriptionStore(file: blocked.appendingPathComponent("subscriptions.json"))
        await #expect(throws: (any Error).self) { try await store.upsert(RuleSubscription(name: "包", url: "https://example.invalid/pack.json")) }
        #expect(store.subscriptions.isEmpty && store.writeCount == 0)
        #expect(try Data(contentsOf: blocked) == bytes)
    }
}

private actor SubscriptionBytes {
    private var bytes: Data
    private(set) var count = 0
    init(_ bytes: Data) { self.bytes = bytes }
    func read() -> Data { count += 1; return bytes }
    func set(_ value: Data) { bytes = value }
}
private actor SubscriptionLatch {
    private var started = false
    private var startedWaiter: CheckedContinuation<Void, Never>?
    private var response: CheckedContinuation<Data, Never>?
    func read() async -> Data {
        started = true; startedWaiter?.resume(); startedWaiter = nil
        return await withCheckedContinuation { response = $0 }
    }
    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { startedWaiter = $0 }
    }
    func release(_ bytes: Data) { response?.resume(returning: bytes); response = nil }
}
