import Darwin
import Foundation
import Testing
@testable import yuedu_app

@Suite("S8 synthetic 307-source scale", .serialized)
@MainActor
struct S8ScaleAcceptanceTests {
    @Test("307 synthetic RSS configs import, persist once, reload and remain idempotent")
    func importPersistReloadAndMeasure() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("S8ScaleAcceptance-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            do { try FileManager.default.removeItem(at: directory) }
            catch { Issue.record("无法清理隔离S8测试目录") }
        }

        let baselineMemory = Self.processMemory()
        let payload = try await Task.detached(priority: .utility) {
            let entries: [[String: Any]] = (0..<307).map { index in
                let group = "Synthetic group \(index % 7)"
                var entry: [String: Any] = [
                    "sourceUrl": "https://synthetic-\(index).fixture.invalid/feed",
                    "sourceName": "Synthetic source \(index)",
                    "sourceGroup": group,
                    "singleUrl": false,
                    "enabled": true,
                    "ruleArticles": "article.entry",
                    "ruleTitle": "h2.title@text",
                    "ruleLink": "a@href",
                    "ruleDescription": "div.summary@html",
                ]
                if index.isMultiple(of: 3) { entry["ruleNextPage"] = "PAGE" }
                if index.isMultiple(of: 5) { entry["ruleImage"] = "img@src" }
                if index.isMultiple(of: 11) { entry["rulePubDate"] = "time@datetime" }
                return entry
            }
            return try JSONSerialization.data(withJSONObject: entries, options: [.sortedKeys])
        }.value

        let loadStart = ContinuousClock.now
        let loaded = try await RSSImportService.load(.data(payload))
        let loadDuration = Self.milliseconds(since: loadStart)
        var memorySamples = [Self.processMemory()].compactMap { $0 }
        let afterLoadMemory = Self.processMemory()
        if let afterLoadMemory { memorySamples.append(afterLoadMemory) }
        #expect(loaded.candidates.count == 307)
        #expect(loaded.candidates.allSatisfy { $0.source != nil && $0.issue == nil })
        #expect(loaded.requests == 0, "synthetic configuration import must not make network requests")

        let store = RSSStore(storageDirectory: directory)
        let compareStart = ContinuousClock.now
        let plan = try await RSSImportService.compare(loaded, with: store.importSnapshot())
        let compareDuration = Self.milliseconds(since: compareStart)
        if let sample = Self.processMemory() { memorySamples.append(sample) }
        #expect(plan.additions == 307 && plan.errors == 0 && plan.skips == 0)

        let mergeStart = ContinuousClock.now
        let changes = try await RSSImportService.changes(for: plan, selected: plan.initialSelection)
        let mergeDuration = Self.milliseconds(since: mergeStart)
        if let sample = Self.processMemory() { memorySamples.append(sample) }
        #expect(changes.added == 307 && changes.changedIDs.count == 307)

        let persistStart = ContinuousClock.now
        try await store.commitImport(changes)
        let persistDuration = Self.milliseconds(since: persistStart)
        if let sample = Self.processMemory() { memorySamples.append(sample) }
        let firstWrites = store.writeCounts
        #expect(store.sources.count == 307)
        #expect(firstWrites["rss_sources.json"] == 1)
        #expect(firstWrites["rss_folders.json"] == 1)

        let reloadStart = ContinuousClock.now
        let reopened = RSSStore(storageDirectory: directory)
        let reloadDuration = Self.milliseconds(since: reloadStart)
        if let sample = Self.processMemory() { memorySamples.append(sample) }
        #expect(reopened.sources.count == 307)
        #expect(Set(reopened.sources.map(\.sourceKey)).count == 307)

        let repeatPlan = try await RSSImportService.compare(loaded, with: reopened.importSnapshot())
        #expect(repeatPlan.skips == 307 && repeatPlan.updates == 0 && repeatPlan.errors == 0)
        let noChanges = try await RSSImportService.changes(for: repeatPlan, selected: repeatPlan.initialSelection)
        try await reopened.commitImport(noChanges)
        #expect(reopened.writeCounts.isEmpty, "unchanged import must not rewrite any file")
        if let sample = Self.processMemory() { memorySamples.append(sample) }

        let baselineResident = baselineMemory?.resident ?? memorySamples.first?.resident ?? 0
        let observedResidentDelta = memorySamples.map(\.resident).filter { $0 >= baselineResident }
            .map { $0 - baselineResident }.max() ?? 0
        let processPeakRSS = memorySamples.map(\.peak).max() ?? 0
        let reportMainThread = { Thread.isMainThread }()
        print("S8_SCALE scenario=synthetic-rss-307 bytes=\(payload.count) requests=\(loaded.requests) sourceWrites=\(firstWrites["rss_sources.json", default: 0]) folderWrites=\(firstWrites["rss_folders.json", default: 0]) unchangedWrites=\(reopened.writeCounts.values.reduce(0, +)) loadMs=\(loadDuration) compareMs=\(compareDuration) mergeMs=\(mergeDuration) persistMs=\(persistDuration) reloadMs=\(reloadDuration) sampledResidentDeltaBytes=\(observedResidentDelta) processPeakRSSBytes=\(processPeakRSS) mainThreadAtReport=\(reportMainThread)")
    }

    @Test("loopback多源刷新合并写盘、不变不写与两页浏览实测", arguments: [1, 307])
    func refreshAndPageScale(_ sourceCount: Int) async throws {
        let root = URL.temporaryDirectory.appendingPathComponent("S8RefreshScale-" + UUID().uuidString)
        let server = try VideoStillFixtureServer(directory: root, maximumRequests: sourceCount * 4 + 4)
        server.route { request in
            let parts = request.path.split(separator: "/")
            guard parts.count == 4, parts[0] == "source", let sourceIndex = Int(parts[1]),
                  parts[2] == "page", let page = Int(parts[3]), (1...2).contains(page) else { return nil }
            let items = (0..<5).map { index in
                "<article class='item'><a href='/article/\(sourceIndex)/\(page)/\(index)'>Item \(page)-\(index)</a></article>"
            }.joined()
            let next = page == 1 ? "<a class='next' href='/source/\(sourceIndex)/page/2'>Next</a>" : ""
            return .init(body: Data((items + next).utf8))
        }
        let base = try await server.start()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        let session = URLSession(configuration: configuration)
        defer {
            session.invalidateAndCancel()
            server.stop()
            do { try FileManager.default.removeItem(at: root) }
            catch { Issue.record("无法清理隔离刷新规模测试目录") }
        }
        let sources = await Task.detached(priority: .utility) {
            (0..<sourceCount).map { index in
                var source = RSSSource(id: "s8-source-\(index)", name: "Synthetic \(index)",
                                       url: base.appendingPathComponent("source/\(index)/page/1").absoluteString)
                source.ruleArticles = "article.item"
                source.ruleTitle = "a@text"
                source.ruleLink = "a@href"
                source.ruleNextPage = "a.next@href"
                source.newArticleNotificationsEnabled = false
                return source
            }
        }.value
        let store = RSSStore(storageDirectory: root)
        store.addSources(sources)
        try await store.flushPersistence()
        let memoryBefore = try #require(Self.processMemory())
        let probe = S8MainQueueProbe()
        let firstStart = ContinuousClock.now
        let first = await RSSFeedRefreshService.refreshAll(store: store,
            makeFetcher: { RSSFetcher(session: session) }, notify: { _, _ in })
        let firstMs = Self.milliseconds(since: firstStart)
        #expect(first)
        let firstWrites = store.writeCounts
        #expect(server.requests.count == sourceCount)
        #expect(firstWrites["rss_articles.json"] == 1, "所有源刷新后只写一次文章集合")
        let sampleAfterFirst = try #require(Self.processMemory())

        let repeatStart = ContinuousClock.now
        let repeated = await RSSFeedRefreshService.refreshAll(store: store,
            makeFetcher: { RSSFetcher(session: session) }, notify: { _, _ in })
        let unchangedMs = Self.milliseconds(since: repeatStart)
        #expect(repeated)
        #expect(store.writeCounts["rss_articles.json"] == firstWrites["rss_articles.json"],
                "307个相同响应不能重写文章集合")
        #expect(server.requests.count == sourceCount * 2)

        let pagingStart = ContinuousClock.now
        let paged = await store.performRefreshBatch {
            for source in sources {
                let browser = RSSFeedSession(source: source, store: store, session: session, maxPages: 2)
                await browser.refresh()
                guard browser.error == nil, browser.currentPage == 1 else {
                    Issue.record("合成规模场景第一页失败")
                    return false
                }
                await browser.nextPage()
                guard browser.error == nil, browser.currentPage == 2, !browser.canLoadMore,
                      store.articles(for: source.id, scope: browser.scope).count == 10 else {
                    Issue.record("合成规模场景第二页未追加为10条")
                    return false
                }
            }
            return true
        }
        let pagingMs = Self.milliseconds(since: pagingStart)
        let latency = await probe.finish()
        #expect(latency.samples > 0, "主队列采样必须实际执行，不能把零样本当作零延迟")
        #expect(paged)
        try await store.flushPersistence()
        #expect(server.requests.count == sourceCount * 4)
        #expect(server.requests.allSatisfy { $0.method == "GET" && $0.headers["cookie"] == nil && $0.headers["authorization"] == nil })
        #expect(store.writeCounts["rss_articles.json"] == firstWrites["rss_articles.json", default: 0] + 1,
                "所有源的第二页追加合并成一次落盘")
        let memoryAfter = try #require(Self.processMemory())
        let reloaded = RSSStore(storageDirectory: root)
        #expect(reloaded.allArticles().count == sourceCount * 10)
        let samples = [memoryBefore, sampleAfterFirst, memoryAfter]
        let delta = samples.map(\.resident).filter { $0 >= memoryBefore.resident }.map { $0 - memoryBefore.resident }.max() ?? 0
        print("S8_REFRESH_SCALE sources=\(sourceCount) pages=2 articles=\(sourceCount * 10) requests=\(server.requests.count) firstMs=\(firstMs) unchangedMs=\(unchangedMs) pagingMs=\(pagingMs) articleWrites=\(store.writeCounts["rss_articles.json", default: 0]) unchangedArticleWrites=0 sampledResidentDeltaBytes=\(delta) processPeakRSSBytes=\(memoryAfter.peak) mainQueueMaxDelayMs=\(String(format: "%.2f", latency.maximumMilliseconds)) mainQueueSamples=\(latency.samples)")
    }

    private static func milliseconds(since start: ContinuousClock.Instant) -> Int {
        let duration = start.duration(to: .now).components
        return Int(duration.seconds * 1_000 + duration.attoseconds / 1_000_000_000_000_000)
    }

    private struct MemorySample {
        let resident: UInt64
        let peak: UInt64
    }

    private static func processMemory() -> MemorySample? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return MemorySample(resident: UInt64(info.resident_size), peak: UInt64(info.resident_size_peak))
    }
}

/// 从独立任务定期测量进入MainActor的等待；这是采样间隔，不等待业务状态稳定。
/// 同时最多挂起一次采样，避免主线程忙时积压测试回调。
private struct S8MainQueueProbe {
    struct Sample: Sendable {
        var maximumMilliseconds = 0.0
        var samples = 0
    }
    private let task: Task<Sample, Never>

    init() {
        task = Task.detached(priority: .utility) {
            var result = Sample()
            while !Task.isCancelled {
                let start = ContinuousClock.now
                let elapsed = await MainActor.run { start.duration(to: .now) }.components
                let milliseconds = Double(elapsed.seconds) * 1_000 + Double(elapsed.attoseconds) / 1e15
                result.maximumMilliseconds = max(result.maximumMilliseconds, milliseconds)
                result.samples += 1
                do { try await Task.sleep(for: .milliseconds(16)) }
                catch is CancellationError { break }
                catch {
                    Issue.record(error)
                    break
                }
            }
            return result
        }
    }

    func finish() async -> Sample {
        task.cancel()
        return await task.value
    }
}
