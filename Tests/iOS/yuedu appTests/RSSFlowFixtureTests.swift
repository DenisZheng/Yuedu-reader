import Foundation
import Testing
@testable import yuedu_app

/// S1固定流程输入。标注“现状差异”的用例不代表对齐；后续阶段须改为目标合同。
@Suite("RSS flow fixture baseline", .serialized)
struct RSSFlowFixtureTests {
    @Test("现状差异：RSS动态分类未载入jsLib，仍回退到sourceKey")
    func dynamicCategoryNeedsSharedLibrary() async throws {
        var source = rules(url: "https://fixture.invalid/categories")
        source.jsLib = "function fixtureCategory(){return 'https://fixture.invalid/one'}"
        source.sortUrl = "@js:'One::'+fixtureCategory()"
        #expect(await LegadoRSSScraper.resolveSortEntries(for: source) == [RSSSortEntry(name: "", url: source.url)])
        // 同一输入在已接入jsLib的共享桥可求值；S4应复用而不是另造分类引擎。
        var adapted = BookSource(bookSourceUrl: source.url, bookSourceName: "RSS category fixture")
        adapted.jsLib = source.jsLib ?? ""
        let value = await BookSourceSession.session(for: adapted).withTurn { bridge in
            bridge.evaluateExploreKindScript("'One::'+fixtureCategory()")
        }
        #expect(value == "One::https://fixture.invalid/one")
    }

    @Test("现状差异：合法空列表被解析层作为noArticlesFound抛出")
    func validEmptyListIsStillAnError() async throws {
        let source = rules(url: "https://fixture.invalid/empty")
        var rejectedAsEmpty = false
        do {
            _ = try await SourceScriptThread.run {
                try LegadoRSSScraper.parseArticles(body: "<main>No new items</main>", finalURL: source.url, listRule: "class.item", reverse: false, source: source, jsEngine: JSCoreEngine())
            }
        } catch ScraperError.noArticlesFound { rejectedAsEmpty = true }
        #expect(rejectedAsEmpty, "S1记录现状错误；实现合法空页后需更新此基线")
    }

    @Test("固定响应序列：第二页失败后可重试同一页；重复页仍返回同一身份")
    func retryAndDuplicatePageInput() async throws {
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
        #expect(try await LegadoRSSScraper.scrape(source: source, page: 1).map(\.title) == ["One"])
        var retryableFailure = false
        do {
            _ = try await LegadoRSSScraper.scrape(source: source, page: 2)
        } catch ScraperError.httpError { retryableFailure = true }
        #expect(retryableFailure, "固定第二页第一次请求必须失败")
        let second = try await LegadoRSSScraper.scrape(source: source, page: 2)
        let duplicate = try await LegadoRSSScraper.scrape(source: source, page: 2)
        #expect(second.map(\.title) == ["Two"])
        #expect(second.map(\.id) == duplicate.map(\.id))
        let requests = RSSPageFixtureProtocol.requests(host: host)
        #expect(requests.map { $0.url?.path } == ["/list/1", "/list/2", "/list/2", "/list/2"])
        #expect(requests.allSatisfy { $0.url?.scheme == "https" }, "S1现状：原HTTP会被升级，未修改该生产策略")
        // 响应由URLProtocol固定，页码由测试显式传入；不冒充分页状态机或HTTP传输证明。
    }

    @Test("现状差异：java.put/get未连接条目变量，标题有值而description为空")
    func fieldVariableContinuity() async throws {
        var source = rules(url: "https://fixture.invalid/variables")
        source.ruleTitle = "a@text@js:java.put('entry',result);result"
        source.ruleDescription = "@js:java.get('entry')"
        let input = article("One", link: "/one") + article("Two", link: "/two")
        let snapshot = source
        let items = try await SourceScriptThread.run {
            try LegadoRSSScraper.parseArticles(body: input, finalURL: snapshot.url, listRule: "class.item", reverse: false, source: snapshot, jsEngine: JSCoreEngine())
        }
        #expect(items.map(\.title) == ["One", "Two"])
        // 目标应为["One", "Two"]；S1已复现断点，S4接入RuleData后替换为目标合同。
        #expect(items.map(\.contentHTML) == ["", ""])
    }

    @Test("现状差异：RSS 403尚未到达loginCheckJs")
    func loginCheckIsNotExecutedByRSSFetch() async throws {
        let host = fixtureHost()
        RSSPageFixtureProtocol.serve(host: host, sequences: [
            "/protected": [.init(body: Data("synthetic login wall".utf8), status: 403)],
            "/verified": [.init(body: Data(article("Verified", link: "/one").utf8))]
        ])
        defer { RSSPageFixtureProtocol.remove(host: host) }
        var source = rules(url: "https://\(host)/protected")
        source.loginCheckJs = "java.connect('https://\(host)/verified')"
        var rejectedBeforeLoginCheck = false
        do {
            _ = try await LegadoRSSScraper.scrape(source: source)
        } catch ScraperError.httpError { rejectedBeforeLoginCheck = true }
        #expect(rejectedBeforeLoginCheck, "S1记录尚未接入loginCheckJs的HTTP错误")
        #expect(RSSPageFixtureProtocol.requests(host: host).map { $0.url?.path } == ["/protected"])
    }

    @Test("S3：同源跨分类相同链接使用不同item身份")
    func categoryIdentityCollision() async throws {
        let host = fixtureHost()
        let body = Data(article("Shared", link: "/shared").utf8)
        RSSPageFixtureProtocol.serve(host: host, sequences: ["/a": [.init(body: body)], "/b": [.init(body: body)]])
        defer { RSSPageFixtureProtocol.remove(host: host) }
        let source = rules(url: "https://\(host)/")
        let first = try await LegadoRSSScraper.scrape(source: source, entry: RSSSortEntry(name: "A", url: "https://\(host)/a"))
        let second = try await LegadoRSSScraper.scrape(source: source, entry: RSSSortEntry(name: "B", url: "https://\(host)/b"))
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
