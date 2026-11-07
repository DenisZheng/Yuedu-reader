import Foundation
import Testing
@testable import yuedu_app

/// S1固定流程输入。标注“现状差异”的用例不代表对齐；后续阶段须改为目标合同。
@Suite("RSS flow fixture baseline", .serialized)
struct RSSFlowFixtureTests {
    @Test("S4：RSS动态分类复用源级jsLib")
    func dynamicCategoryNeedsSharedLibrary() async throws {
        var source = rules(url: "https://fixture.invalid/categories")
        source.jsLib = "function fixtureCategory(){return 'https://fixture.invalid/one'}"
        source.sortUrl = "@js:'One::'+fixtureCategory()"
        #expect(try await LegadoRSSScraper.resolveSortEntries(for: source) == [RSSSortEntry(name: "One", url: "https://fixture.invalid/one")])
    }

    @Test("现状差异：合法空列表被解析层作为noArticlesFound抛出")
    func validEmptyListIsStillAnError() async throws {
        let source = rules(url: "https://fixture.invalid/empty")
        var rejectedAsEmpty = false
        do {
            _ = try await SourceScriptThread.run {
                try LegadoRSSScraper.parseArticles(body: "<main>No new items</main>", finalURL: source.url, listRule: "class.item", reverse: false, source: source, bridge: ModernParserBridge(source: RSSRuntime.scriptSource(source)))
            }
        } catch ScraperError.noArticlesFound { rejectedAsEmpty = true }
        #expect(rejectedAsEmpty, "S1记录现状错误；实现合法空页后需更新此基线")
    }

    @Test("固定响应序列：第二页失败后可重试同一页；重复页仍返回同一身份")
    func retryAndDuplicatePageInput() async throws {
        let session = RSSPageFixtureProtocol.makeSession()
        defer { session.invalidateAndCancel() }
        let host = fixtureHost()
        RSSPageFixtureProtocol.serve(host: host, sequences: [
            "/list/1": [.init(body: Data(article("One", link: "/one").utf8))],
            "/list/2": [
                .init(body: Data("retry fixture".utf8), status: 503),
                .init(body: Data(article("Two", link: "/two").utf8)),
                .init(body: Data(article("Two", link: "/two").utf8))
            ]
        ])
        defer { RSSPageFixtureProtocol.remove(host: host) }
        var source = rules(url: "http://\(host)/list/{{page}}")
        source.ruleNextPage = "PAGE"
        #expect(try await LegadoRSSScraper.scrape(source: source, page: 1, requestSession: session).map(\.title) == ["One"])
        var retryableFailure = false
        do {
            _ = try await LegadoRSSScraper.scrape(source: source, page: 2, requestSession: session)
        } catch ScraperError.httpStatus(503) { retryableFailure = true }
        #expect(retryableFailure, "固定第二页第一次请求必须失败")
        let second = try await LegadoRSSScraper.scrape(source: source, page: 2, requestSession: session)
        let duplicate = try await LegadoRSSScraper.scrape(source: source, page: 2, requestSession: session)
        #expect(second.map(\.title) == ["Two"])
        #expect(second.map(\.id) == duplicate.map(\.id))
        let requests = RSSPageFixtureProtocol.requests(host: host)
        #expect(requests.map { $0.url?.path } == ["/list/1", "/list/2", "/list/2", "/list/2"])
        #expect(requests.allSatisfy { $0.url?.scheme == "http" }, "S4按源配置构造请求，不擅自升级scheme")
        // 响应由URLProtocol固定，页码由测试显式传入；不冒充分页状态机或HTTP传输证明。
    }

    @Test("S4：java.put/get贯穿同一条目字段，不串相邻条目")
    func fieldVariableContinuity() async throws {
        var source = rules(url: "https://fixture.invalid/variables")
        source.ruleTitle = "a@text@js:java.put('entry',result);result"
        source.ruleDescription = "@js:java.get('entry')"
        let input = article("One", link: "/one") + article("Two", link: "/two")
        let snapshot = source
        let items = try await SourceScriptThread.run {
            try LegadoRSSScraper.parseArticles(body: input, finalURL: snapshot.url, listRule: "class.item", reverse: false, source: snapshot, bridge: ModernParserBridge(source: RSSRuntime.scriptSource(snapshot)))
        }
        #expect(items.map(\.title) == ["One", "Two"])
        #expect(items.map(\.contentHTML) == ["One", "Two"])
    }

    @Test("S4：RSS 403到达loginCheckJs，使用校验脚本返回的实际响应")
    func loginCheckIsExecutedByRSSFetch() async throws {
        let session = RSSPageFixtureProtocol.makeSession()
        defer { session.invalidateAndCancel() }
        let host = fixtureHost()
        RSSPageFixtureProtocol.serve(host: host, sequences: [
            "/protected": [.init(body: Data("synthetic login wall".utf8), status: 403)],
            "/verified": [.init(body: Data(article("Verified", link: "/one").utf8))]
        ])
        defer { RSSPageFixtureProtocol.remove(host: host) }
        var source = rules(url: "https://\(host)/protected")
        source.loginCheckJs = "java.connect('https://\(host)/verified')"
        let items = try await LegadoRSSScraper.scrape(source: source, requestSession: session)
        #expect(items.map(\.title) == ["Verified"])
        #expect(RSSPageFixtureProtocol.requests(host: host).map { $0.url?.path } == ["/protected", "/verified"])
    }

    @Test("S3：同源跨分类相同链接使用不同item身份")
    func categoryIdentityCollision() async throws {
        let session = RSSPageFixtureProtocol.makeSession()
        defer { session.invalidateAndCancel() }
        let host = fixtureHost()
        let body = Data(article("Shared", link: "/shared").utf8)
        RSSPageFixtureProtocol.serve(host: host, sequences: ["/a": [.init(body: body)], "/b": [.init(body: body)]])
        defer { RSSPageFixtureProtocol.remove(host: host) }
        let source = rules(url: "https://\(host)/")
        let first = try await LegadoRSSScraper.scrape(source: source, entry: RSSSortEntry(name: "A", url: "https://\(host)/a"), requestSession: session)
        let second = try await LegadoRSSScraper.scrape(source: source, entry: RSSSortEntry(name: "B", url: "https://\(host)/b"), requestSession: session)
        #expect(first.count == 1 && second.count == 1)
        #expect(first.map(\.id) != second.map(\.id))
        #expect(first.map(\.rawKey) == second.map(\.rawKey))
    }

    @MainActor
    @Test("旧OPML追加入口只新增；JSON更新已由S2确认用例覆盖：旧批量导入只新增，同key配置更新被跳过且不会替换本地id")
    func reimportSkipsChangedConfiguration() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("rss-update-fixture-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer {
            do { try FileManager.default.removeItem(at: folder) }
            catch { Issue.record(error) }
        }
        let store = RSSStore(storageDirectory: folder)
        let original = rules(url: "https://fixture.invalid/config#stable")
        #expect(store.addSourcesReturningAdded([original]).count == 1)
        var updated = rules(url: original.url)
        updated.ruleTitle = "h2@text"
        #expect(store.addSourcesReturningAdded([updated]).isEmpty)
        #expect(store.sources.first?.id == original.id)
        #expect(store.sources.first?.ruleTitle == original.ruleTitle)
    }

    @Test("原生路径明确拒绝DASH文本和链接，而非当作MP4成功")
    func nativeDASHIsRestricted() {
        for content in ["<MPD xmlns='urn:mpeg:dash:schema:mpd:2011'></MPD>", "https://fixture.invalid/video.mpd"] {
            #expect(throws: VideoChapterLinkError.dashManifest) { try DirectChapterVideoResolver.link(from: content) }
        }
    }

    private func fixtureHost() -> String { "rss-flow-\(UUID().uuidString.lowercased()).invalid" }

    private func rules(url: String) -> RSSSource {
        var source = RSSSource(name: "RSS flow fixture", url: url)
        source.ruleArticles = "class.item"
        source.ruleTitle = "a@text"
        source.ruleLink = "a@href"
        return source
    }
    private func article(_ title: String, link: String) -> String { "<div class='item'><a href='\(link)'>\(title)</a></div>" }
}
