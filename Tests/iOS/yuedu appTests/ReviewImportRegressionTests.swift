import Foundation
import Testing
@testable import yuedu_app

@Suite("评审导入回归", .serialized)
struct ReviewImportRegressionTests {
    @Test("RSS配置不能被宽容BookSource解码当作空书源")
    func rssCannotBecomeEmptyBookSource() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = BookSourceStore(directory: directory)
        let data = Data(#"[{"sourceUrl":"https://fixture.invalid/feed","sourceName":"订阅"}]"#.utf8)
        #expect(try SharedImportPayloadClassifier.classify(data: data, fileExtension: "json", suggestedFilename: nil) == .rssLegadoJSON)
        #expect(throws: (any Error).self) { try store.parseForImport(data: data, fileExtension: "json") }
        #expect(store.sources.isEmpty)
    }

    @Test("Legado导入将对象header转JSON字符串，小数整数截断，字符串整数回默认值")
    func tolerantLegadoFields() throws {
        let source = try LegadoSourceJSONParser.parseSource(from: [
            "sourceUrl": "opaque", "sourceName": 7, "header": ["X-Fixture": "value"],
            "customOrder": 1.5, "articleStyle": "1"
        ])
        #expect(source.name == "7")
        #expect(source.header == #"{"X-Fixture":"value"}"#)
        #expect(source.customOrder == 1)
        #expect(source.articleStyle == 0, "基准IntJsonDeserializer不把字符串数字当作JSON数字")
    }

    @Test("文件、分享和rssSource/auto/bookSource深链都进入RSS预览，书源库不写入")
    @MainActor func entryPointsUseRSSReview() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { do { try FileManager.default.removeItem(at: directory) } catch { Issue.record(error) } }
        let books = BookSourceStore(directory: directory.appendingPathComponent("books"))
        await books.waitUntilLoaded()
        let rss = RSSStore(storageDirectory: directory.appendingPathComponent("rss"))
        let data = Data(#"[{"sourceUrl":"https://fixture.invalid/feed","sourceName":"订阅","jsLib":"throw new Error('must not run')"}]"#.utf8)
        let file = directory.appendingPathComponent("rss.json")
        try data.write(to: file)
        let fromFile = try await RSSImportService.load(.file(file))
        #expect(fromFile.candidates.first?.source?.sourceKey == "https://fixture.invalid/feed")
        let suite = "review-import-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let payload = SharedImportQueueDrainer.QueuedPayload(storageKind: .remoteURL, remoteURLString: "https://fixture.invalid/rss.json")
        defaults.set([try JSONEncoder().encode(payload)], forKey: SharedImportQueueDrainer.payloadQueueKey)
        let drainer = SharedImportQueueDrainer(defaults: defaults, fetchURL: { _ in data })
        let shared = await drainer.drain()
        #expect(shared.failureCount == 0 && shared.importedCount == 0)
        #expect(drainer.bookSourceReviewRequests.isEmpty)
        #expect(try await RSSImportService.load(try #require(drainer.rssReviewRequest).input).candidates.first?.source?.sourceKey == "https://fixture.invalid/feed")
        for scheme in ["readerfork-dev", "legado", "yuedu"] {
            for kind in ["rssSource", "auto", "bookSource"] {
                let handler = BookSourceDeepLinkHandler(bookStore: books, rssStore: rss, fetch: { _, maximum in
                    let onMain = { Thread.isMainThread }()
                    #expect(!onMain)
                    #expect(maximum == 8 * 1024 * 1024)
                    return data
                })
                handler.handle(url: try #require(URL(string: "\(scheme)://import/\(kind)?src=https://fixture.invalid/rss.json")))
                handler.confirm()
                await handler.waitForWork()
                guard case .reviewingRSS(let request) = handler.phase else { Issue.record("RSS深链未进入RSS预览"); continue }
                #expect(try await RSSImportService.load(request.input).candidates.first?.source?.sourceKey == "https://fixture.invalid/feed")
                #expect(handler.coordinator.pending == nil)
                handler.cancel()
            }
        }
        #expect(books.sources.isEmpty && rss.sources.isEmpty)
    }

    @Test("字段修正数量进入比较预览，不仅改变解码期望")
    func correctedFieldsReachReview() async throws {
        let data = Data(#"{"sourceUrl":"opaque","sourceName":7,"header":{"X-Fixture":"value"},"customOrder":1.5,"articleStyle":"1"}"#.utf8)
        let loaded = try await RSSImportService.load(.data(data))
        let plan = try await RSSImportService.compare(loaded, with: .init(revision: 0, sources: [], folders: []))
        #expect(plan.rows.first?.correctedFields == 4)
        #expect(plan.rows.first?.disposition == .add && plan.errors == 0)
    }

    @Test("下载取消后晚到结果不能打开确认页或写入库")
    @MainActor func cancelledDeepLinkDropsLatePayload() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let books = BookSourceStore(directory: directory)
        await books.waitUntilLoaded()
        let (stream, continuation) = AsyncStream<CheckedContinuation<Data, Never>>.makeStream()
        defer { continuation.finish() }
        let handler = BookSourceDeepLinkHandler(bookStore: books, fetch: { _, _ in
            await withCheckedContinuation { continuation.yield($0) }
        })
        handler.handle(url: try #require(URL(string: "readerfork-dev://import/rssSource?src=https://fixture.invalid/rss.json")))
        handler.confirm()
        var iterator = stream.makeAsyncIterator()
        let held = try #require(await iterator.next())
        handler.cancel()
        held.resume(returning: Data(#"{"sourceUrl":"fixture","sourceName":"订阅"}"#.utf8))
        await handler.waitForWork()
        #expect(handler.phase == .idle && handler.coordinator.pending == nil)
        #expect(books.sources.isEmpty)
    }

    @Test("嵌套sourceUrls不能主动访问localhost或私网地址")
    func nestedPrivateURLsAreRejectedBeforeFetching() async throws {
        let data = Data(#"{"sourceUrls":["http://localhost/pack","http://127.0.0.1/pack","http://192.168.1.1/pack","http://[::1]/pack"]}"#.utf8)
        let loaded = try await RSSImportService.load(.data(data), fetch: { _, _ in
            Issue.record("嵌套包在拒绝前已经发出下载")
            return Data(#"{"sourceUrl":"fixture","sourceName":"订阅"}"#.utf8)
        })
        #expect(loaded.requests == 0)
        #expect(loaded.candidates.count == 4)
        #expect(loaded.candidates.allSatisfy { $0.issue == .invalidURL })
    }
}
