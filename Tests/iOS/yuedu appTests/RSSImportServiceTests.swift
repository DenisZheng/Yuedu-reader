import Foundation
import Testing
@testable import yuedu_app

@Suite("S2 RSS import use case", .serialized)
struct RSSImportServiceTests {
    private func data(_ value: Any) throws -> Data { try JSONSerialization.data(withJSONObject: value) }
    private func source(_ key: String = "key#{{page}}") -> [String: Any] { ["sourceUrl": key, "sourceName": "Fixture"] }
    private func empty() -> RSSImportService.Snapshot { .init(revision: 0, sources: [], folders: []) }
    private func cleanup(_ url: URL) {
        do { try FileManager.default.removeItem(at: url) }
        catch { Issue.record("无法清理隔离测试目录") }
    }

    @Test("逐项错误不抹去合法项，配置解析不执行脚本")
    func mixedEntries() async throws {
        var good = source()
        good["jsLib"] = "throw new Error('must never execute')"
        let loaded = try await RSSImportService.load(.data(data([good, ["sourceName": "bad"], 7, ["sourceUrl": "unnamed"], ["sourceUrl": "badtype", "type": true]])))
        #expect(loaded.candidates.count == 5)
        #expect(loaded.candidates.filter { $0.source != nil }.count == 2)
        #expect(loaded.candidates.filter { $0.issue == .invalidFormat }.count == 3)
        #expect(loaded.requests == 0)
    }

    @Test("单对象和数组进入同一比较；重复key首项优先并可披露未知字段")
    func duplicateKeys() async throws {
        var a = source(); a["future"] = [true, false]
        var b = source(); b["ruleContent"] = "do not overwrite first"
        let loaded = try await RSSImportService.load(.data(data([a, b, source("key#second")])))
        let plan = try await RSSImportService.compare(loaded, with: empty())
        #expect(plan.rows.map(\.disposition) == [.add, .duplicate, .add])
        #expect(plan.rows.first?.unknownFields == 1)
        let selected = Set(plan.rows.map(\.id))
        let changes = try await RSSImportService.changes(for: plan, selected: selected)
        #expect(changes.added == 2 && changes.skipped == 1)
        #expect(changes.sources.first?.ruleContent == nil)
    }

    @Test("递归包受层级、重复URL、数量和大小预算约束")
    func recursiveLimits() async throws {
        let root = try data(["sourceUrls": ["https://fixture.invalid/a", "https://fixture.invalid/a#again", "file:///private/data"]])
        let child = try data([source("first")])
        let loaded = try await RSSImportService.load(.data(root), fetch: { _, _ in child })
        #expect(loaded.requests == 1)
        #expect(loaded.candidates.map(\.issue) == [nil, .repeatedURL, .invalidURL])
        let nested = try data(["sourceUrls": ["https://fixture.invalid/b"]])
        let deep = try await RSSImportService.load(.data(root), limits: .init(depth: 1), fetch: { _, _ in nested })
        #expect(deep.candidates.first?.issue == .depthLimit)
        let capped = try await RSSImportService.load(.data(data([source("1"), source("2"), source("3")])), limits: .init(entries: 2))
        #expect(capped.candidates.count == 3 && capped.candidates.last?.issue == .entryLimit)
        let oversized = try await RSSImportService.load(.data(root), limits: .init(bytesPerDocument: 4))
        #expect(oversized.candidates.first?.issue == .responseTooLarge)
        let many = try await RSSImportService.load(.data(root), limits: .init(documents: 0))
        #expect(many.requests == 0 && many.candidates.first?.issue == .documentLimit)
    }

    @Test("失败包有脱敏报告，用户取消向上传播而不是成功空列表")
    func failureAndCancellation() async throws {
        let input = RSSImportService.Input.remote(URL(string: "https://fixture.invalid/private?token=secret")!)
        let failure = try await RSSImportService.load(input, fetch: { _, _ in throw URLError(.timedOut) })
        #expect(failure.candidates.first?.issue == .network)
        #expect(failure.candidates.first?.location == "1")
        await #expect(throws: CancellationError.self) {
            try await RSSImportService.load(input, fetch: { _, _ in throw CancellationError() })
        }
    }

    @Test("真实URLSession包下载有响应检查和解压后字节上限")
    func boundedDownload() async throws {
        let body = try data(source())
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/VideoStill")
        let server = try VideoStillFixtureServer(directory: directory, routes: [
            "/ok": .init(body: body), "/large": .init(body: body),
            "/error": .init(body: body, status: "503 Service Unavailable")
        ])
        let base = try await server.start()
        defer { server.stop() }
        let loaded = try await RSSImportService.load(.remote(base.appendingPathComponent("ok")))
        #expect(loaded.candidates.first?.source?.sourceKey == "key#{{page}}")
        await #expect(throws: RSSImportService.Issue.responseTooLarge) {
            try await RSSImportService.download(base.appendingPathComponent("large"), maximumBytes: 4)
        }
        await #expect(throws: RSSImportService.Issue.network) {
            try await RSSImportService.download(base.appendingPathComponent("error"), maximumBytes: 1000)
        }
        #expect(server.requests.count == 3)
        #expect(server.requests.allSatisfy { $0.headers["cookie"] == nil && $0.headers["authorization"] == nil })
    }

    @MainActor
    @Test("比较前不写盘；更新保留本地身份及组织设置，重导不写")
    func updateAndIdempotence() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { cleanup(folder) }
        let store = RSSStore(storageDirectory: folder)
        var initial = source(); initial["sourceGroup"] = "Remote"; initial["ruleContent"] = "old"
        let first = try await RSSImportService.load(.data(data(initial)))
        let plan = try await RSSImportService.compare(first, with: store.importSnapshot())
        #expect(store.sources.isEmpty && store.writeCounts.isEmpty)
        let changes = try await RSSImportService.changes(for: plan, selected: Set(plan.rows.map(\.id)))
        try await store.commitImport(changes)
        var old = try #require(store.sources.first)
        old.name = "Local name"; old.sourceGroup = "Local group"; old.enabled = false
        old.newArticleNotificationsEnabled = false
        store.updateSource(old)
        try await store.flushPersistence()
        var update = initial; update["ruleContent"] = "new"; update["sourceName"] = "Remote change"
        let next = try await RSSImportService.load(.data(data(update)))
        let diff = try await RSSImportService.compare(next, with: store.importSnapshot())
        #expect(diff.rows.first?.disposition == .update)
        let commit = try await RSSImportService.changes(for: diff, selected: Set(diff.rows.map(\.id)))
        try await store.commitImport(commit)
        let restored = RSSStore(storageDirectory: folder)
        let actual = try #require(restored.sources.first)
        #expect(actual.id == old.id && actual.name == "Local name" && actual.sourceGroup == "Local group")
        #expect(!actual.enabled && !actual.newArticleNotificationsEnabled && actual.ruleContent == "new")
        let before = store.writeCounts
        let repeatPlan = try await RSSImportService.compare(next, with: store.importSnapshot())
        #expect(repeatPlan.rows.first?.disposition == .unchanged)
        let noChanges = try await RSSImportService.changes(for: repeatPlan, selected: Set(repeatPlan.rows.map(\.id)))
        try await store.commitImport(noChanges)
        #expect(store.writeCounts == before)
    }

    @MainActor
    @Test("确认后先保存，首次刷新失败/取消不撤回配置")
    func sessionSaveBeforeRefresh() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { cleanup(folder) }
        let store = RSSStore(storageDirectory: folder)
        let session = RSSImportSession(store: store)
        var value = source("https://fixture.invalid/feed")
        value["singleUrl"] = false
        await session.load(.data(try data(value)))
        #expect(session.phase == .review && store.sources.isEmpty)
        session.confirm()
        await session.waitForWork()
        #expect(session.phase == .saved)
        let saved = RSSStore(storageDirectory: folder)
        #expect(saved.sources.count == 1)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [RSSImportFailureProtocol.self]
        let network = URLSession(configuration: config)
        defer { network.invalidateAndCancel() }
        session.refresh(makeFetcher: { RSSFetcher(session: network) })
        await session.waitForWork()
        #expect(session.phase == .saved && !session.isRefreshing)
        #expect(session.refreshMessage == localized("配置已儲存，但首次刷新失敗，可稍後重試"))
        #expect(store.sources.count == 1)
        session.refresh(makeFetcher: { RSSFetcher(session: network) })
        session.cancelRefresh()
        await session.waitForWork()
        #expect(session.refreshMessage == localized("刷新已取消，已儲存的配置不受影響"))
        #expect(RSSStore(storageDirectory: folder).sources.count == 1)

        let cancelled = RSSImportSession(store: store)
        await cancelled.load(.data(try data(source("second"))))
        cancelled.cancel()
        #expect(store.sources.count == 1)
    }

    @Test("旧Fork数据无需新字段仍可解码；损坏配置不被空状态覆盖")
    @MainActor
    func oldStorageAndCorruption() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { cleanup(folder) }
        let old = RSSSource(name: "Old", url: "old")
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(old)) as? [String: Any])
        json.removeValue(forKey: "configurationVersion")
        let legacy = try data([json])
        let file = folder.appendingPathComponent("rss_sources.json")
        try legacy.write(to: file)
        #expect(RSSStore(storageDirectory: folder).sources.first?.id == old.id)
        let corrupt = Data("not json".utf8)
        try corrupt.write(to: file)
        let store = RSSStore(storageDirectory: folder)
        store.addSource(RSSSource(name: "Not saved", url: "new"))
        await #expect(throws: RSSImportService.Issue.persistence) { try await store.flushPersistence() }
        #expect(try Data(contentsOf: file) == corrupt)
    }

    @MainActor
    @Test("确认前的删除/编辑使旧计划失效，不复活源")
    func staleConfirmation() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { cleanup(folder) }
        let store = RSSStore(storageDirectory: folder)
        let loaded = try await RSSImportService.load(.data(data(source())))
        let plan = try await RSSImportService.compare(loaded, with: store.importSnapshot())
        let changes = try await RSSImportService.changes(for: plan, selected: Set(plan.rows.map(\.id)))
        store.addSource(RSSSource(name: "Concurrent", url: "other"))
        await #expect(throws: RSSImportService.Issue.stalePlan) { try await store.commitImport(changes) }
        try await store.flushPersistence()
        #expect(store.sources.map(\.url) == ["other"])
    }

    @MainActor
    @Test("磁盘写失败不回报成功，可重试；原始key不被Feed发现覆盖")
    func persistenceAndResolvedURL() async throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data().write(to: path)
        defer { cleanup(path) }
        let store = RSSStore(storageDirectory: path)
        let loaded = try await RSSImportService.load(.data(data(source())))
        let plan = try await RSSImportService.compare(loaded, with: store.importSnapshot())
        let changes = try await RSSImportService.changes(for: plan, selected: Set(plan.rows.map(\.id)))
        await #expect(throws: RSSImportService.Issue.persistence) { try await store.commitImport(changes) }
        #expect(store.writeCounts.isEmpty)
        try FileManager.default.removeItem(at: path)
        try await store.retryPersistence()
        #expect(store.writeCounts["rss_sources.json"] == 1)
        let id = try #require(store.sources.first?.id)
        store.applyResolvedFeedURL("https://resolved.invalid/feed", homepageURL: nil, to: id)
        try await store.flushPersistence()
        #expect(store.sources.first?.sourceKey == "key#{{page}}")
        #expect(store.sources.first?.resolvedFeedURL == "https://resolved.invalid/feed")
    }
}

private final class RSSImportFailureProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet)) }
    override func stopLoading() {}
}
