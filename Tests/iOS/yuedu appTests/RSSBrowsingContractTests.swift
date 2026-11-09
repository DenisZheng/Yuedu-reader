import Foundation
import Testing
@testable import yuedu_app

/// S5用例边界：固定HTTP输入经过生产fetcher/runtime，观察响应、分页和store状态。
@Suite("RSS browsing contracts", .serialized)
@MainActor
struct RSSBrowsingContractTests {
    @Test("列表next以请求URL为基址，文章与正文next以redirectURL为基址")
    func redirectedPageBases() async throws {
        let server = try VideoStillFixtureServer(directory: .temporaryDirectory, routes: [
            "/base/list": .init(body: Data(), status: "302 Found", headers: ["Location": "/moved/list"]),
            "/moved/list": .init(body: Data("<div class='item'><a href='article'>One</a></div><a class='next' href='next'>Next</a>".utf8)),
            "/base/next": .init(body: Data("<div class='item'><a href='/two'>Two</a></div>".utf8)),
            "/base/story": .init(body: Data(), status: "302 Found", headers: ["Location": "/moved/story"]),
            "/moved/story": .init(body: Data("<p>First</p><a class='next' href='chapter-2'>Next</a>".utf8)),
            "/moved/chapter-2": .init(body: Data("<p>Second</p>".utf8))
        ])
        let base = try await server.start()
        defer { server.stop() }
        var source = RSSSource(name: "Bases", url: base.appendingPathComponent("base/list").absoluteString)
        source.ruleArticles = "class.item"; source.ruleTitle = "a@text"; source.ruleLink = "a@href"
        source.ruleNextPage = "a.next@href"; source.ruleContent = "p@text"; source.nextContentUrl = "a.next@href"
        let first = try await LegadoRSSScraper.fetchListPage(source: source)
        #expect(first.nextURL == base.appendingPathComponent("base/next").absoluteString)
        #expect(first.items.first?.link == base.appendingPathComponent("moved/article").absoluteString)
        let second = try await LegadoRSSScraper.fetchListPage(source: source, page: 2, requestURL: first.nextURL)
        #expect(second.nextURL == nil, "未匹配下一页不能回退为当前页面URL")
        #expect(try await LegadoRSSScraper.fetchArticleContent(source: source, articleLink: base.appendingPathComponent("base/story").absoluteString) == "First\nSecond")
        #expect(server.requests.map(\.path) == ["/base/list", "/moved/list", "/base/next", "/base/story", "/moved/story", "/moved/chapter-2"])
    }

    @Test("动态请求URL改变时不沿用旧validator，相同目标才发送条件头")
    func validatorsFollowResolvedRequest() async throws {
        let host = "rss-dynamic-validator-\(UUID().uuidString.lowercased()).invalid"
        let session = RSSPageFixtureProtocol.makeSession()
        let body = Data("<rss version='2.0'><channel><title>Feed</title></channel></rss>".utf8)
        RSSPageFixtureProtocol.serve(host: host, sequences: [
            "/one": [.init(body: body, contentType: "application/rss+xml", headers: ["ETag": "one"])],
            "/two": [.init(body: body, contentType: "application/rss+xml", headers: ["ETag": "two"]), .init(body: Data(), status: 304)]
        ])
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {
            session.invalidateAndCancel(); RSSPageFixtureProtocol.remove(host: host)
            do { try FileManager.default.removeItem(at: directory) } catch { Issue.record(error) }
        }
        let store = RSSStore(storageDirectory: directory)
        var source = RSSSource(name: "Dynamic", url: "@js:'https://\(host)/'+(++sequence===1?'one':'two')")
        source.importedFromLegado = true; source.jsLib = "var sequence=0;"
        store.addSource(source)
        let browser = RSSFeedSession(source: source, store: store, session: session)
        await browser.refresh(); await browser.refresh(); await browser.refresh()
        #expect(browser.error == nil)
        #expect(RSSPageFixtureProtocol.requests(host: host).map { $0.value(forHTTPHeaderField: "If-None-Match") } == [nil, nil, "two"])
        try await store.flushPersistence()
    }

    @Test("普通Feed的304保留缓存，远程查询不共享metadata，配置修改使validator失效")
    func feedValidatorsAndSearchScope() async throws {
        let host = "rss-validators-\(UUID().uuidString.lowercased()).invalid"
        let session = RSSPageFixtureProtocol.makeSession()
        func feed(_ title: String) -> Data {
            Data("<rss version='2.0'><channel><title>Feed</title><item><guid>same</guid><title>\(title)</title><link>https://\(host)/article</link></item></channel></rss>".utf8)
        }
        RSSPageFixtureProtocol.serve(host: host, sequences: [
            "/feed": [.init(body: feed("Initial"), contentType: "application/rss+xml", headers: ["ETag": "feed-tag"]),
                      .init(body: Data(), status: 304),
                      .init(body: feed("Changed"), contentType: "application/rss+xml")],
            "/search": [.init(body: feed("Query"), contentType: "application/rss+xml", headers: ["ETag": "query-tag"]),
                        .init(body: Data(), status: 304)]
        ])
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {
            session.invalidateAndCancel(); RSSPageFixtureProtocol.remove(host: host)
            do { try FileManager.default.removeItem(at: directory) } catch { Issue.record(error) }
        }
        let store = RSSStore(storageDirectory: directory)
        var source = RSSSource(name: "Validators", url: "https://\(host)/feed")
        source.importedFromLegado = true
        source.searchUrl = "https://\(host)/search?q={{key}}"
        store.addSource(source)
        let browser = RSSFeedSession(source: source, store: store, session: session)
        await browser.refresh()
        await browser.refresh()
        #expect(store.articles(for: source.id, scope: browser.scope).map(\.title) == ["Initial"])
        #expect(store.feedMetadata(for: source.id)?.etag == "feed-tag")
        await browser.refresh(key: "needle")
        await browser.refresh(key: "needle")
        #expect(browser.scope == .search("needle"))
        #expect(store.articles(for: source.id, scope: browser.scope).map(\.title) == ["Query"])
        #expect(store.feedMetadata(for: source.id)?.etag == "feed-tag")
        source.header = #"{"X-Revision":"new"}"#
        store.updateSource(source)
        await browser.refresh()
        #expect(store.articles(for: source.id, scope: browser.scope).map(\.title) == ["Changed"])
        let requests = RSSPageFixtureProtocol.requests(host: host)
        #expect(requests.map { $0.value(forHTTPHeaderField: "If-None-Match") } == [nil, "feed-tag", nil, nil, nil])
        try await store.flushPersistence()
    }

    @Test("后台刷新不执行前台startHtml脚本")
    func backgroundIgnoresStartupHTML() async throws {
        let host = "rss-background-start-\(UUID().uuidString.lowercased()).invalid"
        let session = RSSPageFixtureProtocol.makeSession()
        RSSPageFixtureProtocol.serve(host: host, contentType: "text/html", body: Data("<div class='item'><a href='/one'>One</a></div>".utf8))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {
            session.invalidateAndCancel(); RSSPageFixtureProtocol.remove(host: host)
            do { try FileManager.default.removeItem(at: directory) } catch { Issue.record(error) }
        }
        let store = RSSStore(storageDirectory: directory)
        var source = RSSSource(name: "Background", url: "https://\(host)/list")
        source.ruleArticles = "class.item"; source.ruleTitle = "a@text"; source.ruleLink = "a@href"
        source.startHtml = "@js:throw new Error('Must not run in background')"
        store.addSource(source)
        #expect(await RSSFeedRefreshService.refreshAll(store: store, makeFetcher: { RSSFetcher(session: session) }, notify: { _, _ in }))
        #expect(store.articles(for: source.id).map(\.title) == ["One"])
        try await store.flushPersistence()
    }

    @Test("正文首组多链接按顺序合并，各分支继承首页变量且不递归；循环与预算有部分标记")
    func contentBranchesAndLimits() async throws {
        let host = "rss-branches-\(UUID().uuidString.lowercased()).invalid"
        let session = RSSPageFixtureProtocol.makeSession()
        RSSPageFixtureProtocol.serve(host: host, sequences: [
            "/start": [.init(body: Data("<p>A</p><a href='/two'>2</a><a href='/three'>3</a>".utf8))],
            "/two": [.init(body: Data("<p>B</p><a href='/ignored'>ignored</a>".utf8))],
            "/three": [.init(body: Data("<p>C</p>".utf8))],
            "/loop": [.init(body: Data("<p>X</p><a href='/loop'>loop</a>".utf8))],
            "/limit": [.init(body: Data("<p>L</p><a href='/never'>next</a>".utf8))]
        ])
        defer { session.invalidateAndCancel(); RSSPageFixtureProtocol.remove(host: host) }
        var source = RSSSource(name: "Branches", url: "https://\(host)/")
        source.ruleContent = "p@text@js:(function(){var before=java.get('n')||'0';java.put('n',String(Number(before)+1));return result+'|'+before;})()"
        source.nextContentUrl = "a@href"
        let branches = try await LegadoRSSScraper.fetchArticleContentResult(source: source, articleLink: "https://\(host)/start", requestSession: session)
        #expect(branches.html == "A|0\nB|1\nC|1")
        #expect(branches.pageCount == 3 && !branches.isPartial && branches.variables["n"] == "2")
        let loop = try await LegadoRSSScraper.fetchArticleContentResult(source: source, articleLink: "https://\(host)/loop", requestSession: session)
        #expect(loop.stop == .loop && loop.isPartial && loop.pageCount == 1)
        let budget = try await LegadoRSSScraper.fetchArticleContentResult(source: source, articleLink: "https://\(host)/limit", maxPages: 1, requestSession: session)
        #expect(budget.stop == .budget && budget.isPartial && budget.pageCount == 1)
        #expect(RSSPageFixtureProtocol.requests(host: host).compactMap { $0.url?.path } == ["/start", "/two", "/three", "/loop", "/limit"])
    }

    @Test("startHtml可动态求值，空结果回列表；网页请求保留URL options和源头")
    func startupHTMLAndRequest() async throws {
        let session = RSSPageFixtureProtocol.makeSession()
        defer { session.invalidateAndCancel() }
        var source = RSSSource(name: "Start", url: "https://start.invalid/base")
        source.jsLib = "function startup(){return '<button>Go</button>'}"
        source.startHtml = "@js:startup()"
        #expect(try await RSSOpenTarget.resolve(source: source, session: session) == .html("<button>Go</button>", baseURL: source.url))
        source.startHtml = "@js:''"
        #expect(try await RSSOpenTarget.resolve(source: source, session: session) == nil)
        source.singleUrl = true
        source.header = #"{"X-Source":"fixture"}"#
        source.sortUrl = #"https://start.invalid/open#anchor,{"method":"POST","body":"a=1","headers":{"X-Option":"yes"}}"#
        let target = try #require(try await RSSOpenTarget.resolve(source: source, session: session))
        guard case .request(let request, _) = target else { Issue.record("没有生成网页请求"); return }
        #expect(request.httpMethod == "POST")
        #expect(request.httpBody.map { String(decoding: $0, as: UTF8.self) } == "a=1")
        #expect(request.value(forHTTPHeaderField: "X-Source") == "fixture")
        #expect(request.value(forHTTPHeaderField: "X-Option") == "yes")
        #expect(request.url?.fragment == "anchor")
    }

    @Test("描述中的交互HTML优先于旧全文；后页失败保存部分结果，重试可完成")
    func descriptionAndPartialPersistence() async throws {
        let host = "rss-partial-\(UUID().uuidString.lowercased()).invalid"
        let session = RSSPageFixtureProtocol.makeSession()
        RSSPageFixtureProtocol.serve(host: host, sequences: [
            "/one": [.init(body: Data("<p>First</p><a href='/two'>next</a>".utf8)),
                     .init(body: Data("<p>First</p><a href='/two'>next</a>".utf8))],
            "/two": [.init(body: Data("failure".utf8), status: 503), .init(body: Data("<p>Second</p>".utf8))]
        ])
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {
            session.invalidateAndCancel(); RSSPageFixtureProtocol.remove(host: host)
            do { try FileManager.default.removeItem(at: directory) } catch { Issue.record(error) }
        }
        let store = RSSStore(storageDirectory: directory)
        var source = RSSSource(name: "Partial", url: "https://\(host)/")
        source.ruleArticles = "class.item"; source.ruleContent = "p@text"; source.nextContentUrl = "a@href"
        store.addSource(source)
        let interactive = "<button onclick='this.textContent=\"done\"'>Go</button>"
        let described = RSSItem(id: "description", title: "Description", link: "https://\(host)/never", contentHTML: interactive, sourceId: source.id)
        let content = RSSItem(id: "content", title: "Content", link: "https://\(host)/one", sourceId: source.id)
        store.mergeFetchedItems([described, content], for: source.id)
        store.updateFullText(articleId: described.id, text: "Old full text", html: "<p>Old</p>")
        #expect(try await RSSArticleContentService.load(try #require(store.article(id: described.id)), source: source, store: store, session: session))
        #expect(RSSPageFixtureProtocol.requests(host: host).isEmpty)
        #expect(RSSArticleContentService.prefersDescription(try #require(store.article(id: described.id)), source: source))
        #expect(try await !RSSArticleContentService.load(try #require(store.article(id: content.id)), source: source, store: store, session: session))
        try await store.flushPersistence()
        let restored = RSSStore(storageDirectory: directory)
        let partial = try #require(restored.article(id: content.id))
        #expect(partial.fullTextHTML == "First" && partial.fullTextIsPartial == true)
        #expect(try await RSSArticleContentService.load(partial, source: source, store: restored, session: session))
        #expect(restored.article(id: content.id)?.fullTextHTML == "First\nSecond")
        #expect(restored.article(id: content.id)?.fullTextIsPartial == false)
        try await restored.flushPersistence()
    }

    @Test("列表循环与页数预算分别终止，不继续发出请求")
    func listLoopAndBudget() async throws {
        let host = "rss-budget-\(UUID().uuidString.lowercased()).invalid"
        let session = RSSPageFixtureProtocol.makeSession()
        let body = Data("<div class='item'><a href='/one'>One</a></div><a class='next' href='/list/1'>Next</a>".utf8)
        RSSPageFixtureProtocol.serve(host: host, contentType: "text/html", body: body)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {
            session.invalidateAndCancel(); RSSPageFixtureProtocol.remove(host: host)
            do { try FileManager.default.removeItem(at: directory) } catch { Issue.record(error) }
        }
        let store = RSSStore(storageDirectory: directory)
        var source = RSSSource(name: "Bounded", url: "https://\(host)/list/1")
        source.ruleArticles = "class.item"; source.ruleTitle = "a@text"; source.ruleLink = "a@href"
        source.ruleNextPage = "a.next@href"
        store.addSource(source)
        let loop = RSSFeedSession(source: source, store: store, session: session)
        await loop.refresh()
        #expect(loop.end == .loop && !loop.canLoadMore)
        await loop.nextPage()
        source.ruleNextPage = "PAGE"
        store.updateSource(source)
        let budget = RSSFeedSession(source: source, store: store, session: session, maxPages: 1)
        await budget.refresh()
        #expect(budget.end == .budget && !budget.canLoadMore)
        await budget.nextPage()
        #expect(RSSPageFixtureProtocol.requests(host: host).count == 2)
        try await store.flushPersistence()
    }

    @Test("正文顺序翻页继承文章变量；图片和视频保持单结果")
    func contentPagesAndMediaBoundary() async throws {
        let host = "rss-content-\(UUID().uuidString.lowercased()).invalid"
        let session = RSSPageFixtureProtocol.makeSession()
        RSSPageFixtureProtocol.serve(host: host, sequences: [
            "/one": [.init(body: Data("<p>First</p><a href='/two'>next</a>".utf8)), .init(body: Data("<p>Image</p><a href='/two'>next</a>".utf8)), .init(body: Data("<p>Video</p><a href='/two'>next</a>".utf8))],
            "/two": [.init(body: Data("<p>Second</p>".utf8))]
        ])
        defer { session.invalidateAndCancel(); RSSPageFixtureProtocol.remove(host: host) }
        var source = RSSSource(name: "Content", url: "https://\(host)/")
        source.ruleContent = "p@text"
        source.nextContentUrl = "a@href"
        #expect(try await LegadoRSSScraper.fetchArticleContent(source: source, articleLink: "https://\(host)/one", requestSession: session) == "First\nSecond")
        source.contentType = .image
        #expect(try await LegadoRSSScraper.fetchArticleContent(source: source, articleLink: "https://\(host)/one", requestSession: session) == "Image")
        source.contentType = .video
        #expect(try await LegadoRSSScraper.fetchArticleContent(source: source, articleLink: "https://\(host)/one", requestSession: session) == "Video")
        #expect(RSSPageFixtureProtocol.requests(host: host).map { $0.url?.path } == ["/one", "/two", "/one", "/one"])
    }

    @Test("singleUrl优先于分类和列表规则，动态sortUrl使用jsLib且不请求列表")
    func singleURLPrecedence() async throws {
        let host = "rss-open-\(UUID().uuidString.lowercased()).invalid"
        let session = RSSPageFixtureProtocol.makeSession()
        RSSPageFixtureProtocol.serve(host: host, contentType: "text/html", body: Data("<main>Not a list</main>".utf8))
        defer { session.invalidateAndCancel(); RSSPageFixtureProtocol.remove(host: host) }
        for variant in 0..<6 {
            var source = RSSSource(name: "Open", url: "https://\(host)/source")
            source.importedFromLegado = true
            source.singleUrl = true
            if variant % 2 == 0 { source.ruleArticles = "class.item"; source.ruleTitle = "a@text" }
            source.jsLib = "function entryURL(){return 'https://\(host)/start#section'}"
            source.sortUrl = variant < 2 ? "https://\(host)/start#section"
                : variant < 4 ? "Page::https://\(host)/start#section" : "@js:'Page::'+entryURL()"
            source.startHtml = "<p>Must not replace singleUrl</p>"
            let fetcher = RSSFetcher(session: session)
            await fetcher.fetchItems(from: source)
            #expect(fetcher.error == nil)
            #expect(fetcher.webPageURL?.url.absoluteString == "https://\(host)/start#section")
            #expect(fetcher.response == nil)
        }
        #expect(RSSPageFixtureProtocol.requests(host: host).isEmpty)
    }

    @Test("生产分页会话成功才推进，503重试同页，重复页终止并保持文章顺序")
    func paginationRetryAndDuplicate() async throws {
        let host = "rss-session-\(UUID().uuidString.lowercased()).invalid"
        let session = RSSPageFixtureProtocol.makeSession()
        func body(_ title: String) -> Data { Data("<div class='item'><a href='/\(title)'>\(title)</a></div>".utf8) }
        RSSPageFixtureProtocol.serve(host: host, sequences: [
            "/list/1": [.init(body: body("One"))],
            "/list/2": [.init(body: Data("retry".utf8), status: 503), .init(body: body("Two"))],
            "/list/3": [.init(body: body("Two"))]
        ])
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {
            session.invalidateAndCancel(); RSSPageFixtureProtocol.remove(host: host)
            do { try FileManager.default.removeItem(at: directory) } catch { Issue.record(error) }
        }
        let store = RSSStore(storageDirectory: directory)
        var source = RSSSource(name: "Pages", url: "https://\(host)/list/{{page}}")
        source.ruleArticles = "class.item"; source.ruleTitle = "a@text"; source.ruleLink = "a@href"
        source.ruleNextPage = "PAGE"
        store.addSource(source)
        let model = RSSFeedSession(source: source, store: store, session: session)
        await model.refresh()
        #expect(model.currentPage == 1 && model.canLoadMore)
        await model.nextPage()
        #expect(model.currentPage == 1 && model.canRetry && model.error != nil)
        await model.retry()
        #expect(model.currentPage == 2 && model.error == nil)
        #expect(store.articles(for: source.id, scope: model.scope).map(\.title) == ["One", "Two"])
        await model.nextPage()
        #expect(model.currentPage == 3 && model.end == .duplicate && !model.canLoadMore)
        await model.nextPage()
        #expect(RSSPageFixtureProtocol.requests(host: host).map { $0.url?.path } == ["/list/1", "/list/2", "/list/2", "/list/3"])
        try await store.flushPersistence()
    }

    @Test("分类切换取消旧请求，空分类不会显示其他分类或提交晚到结果")
    func categorySwitchCancelsOldPage() async throws {
        let host = "rss-switch-\(UUID().uuidString.lowercased()).invalid"
        let session = RSSPageFixtureProtocol.makeSession()
        let (events, continuation) = AsyncStream<URLRequest>.makeStream()
        RSSPageFixtureProtocol.serve(host: host, sequences: [
            "/a": [.init(body: Data("<div class='item'><a href='/one'>Old</a></div>".utf8), held: true)],
            "/b": [.init(body: Data("<main>Empty</main>".utf8))]
        ], events: continuation)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {
            session.invalidateAndCancel(); continuation.finish(); RSSPageFixtureProtocol.remove(host: host)
            do { try FileManager.default.removeItem(at: directory) } catch { Issue.record(error) }
        }
        let store = RSSStore(storageDirectory: directory)
        var source = RSSSource(name: "Categories", url: "https://\(host)/")
        source.ruleArticles = "class.item"; source.ruleTitle = "a@text"; source.ruleLink = "a@href"
        let a = RSSSortEntry(name: "A", url: "https://\(host)/a")
        let b = RSSSortEntry(name: "B", url: "https://\(host)/b")
        source.sortUrl = "A::\(a.url)&&B::\(b.url)"
        store.addSource(source)
        let cached = RSSItem(id: "kept", title: "Cached", link: "/cached", sourceId: source.id).identified(sourceID: source.id, scope: .category(a))
        store.mergeFetchedItems([cached], for: source.id)
        let model = RSSFeedSession(source: source, store: store, session: session)
        let pending = Task { await model.refresh(entry: a) }
        defer { pending.cancel(); model.cancel() }
        var iterator = events.makeAsyncIterator()
        #expect(await iterator.next()?.url?.path == "/a")
        await model.refresh(entry: b)
        await pending.value
        #expect(model.scope == .category(b) && model.end == .empty)
        #expect(store.articles(for: source.id, scope: model.scope).isEmpty)
        #expect(store.articles(for: source.id, scope: .category(a)).map(\.title) == ["Cached"])
        try await store.flushPersistence()
    }

    @Test("列表下一页与搜索key由同一执行流程返回，页码不改变作用域身份")
    func listPageMetadata() async throws {
        let host = "rss-next-\(UUID().uuidString.lowercased()).invalid"
        let session = RSSPageFixtureProtocol.makeSession()
        let body = "<div class='item'><a href='/same'>Same</a></div><a class='next' href='/next'>Next</a>"
        RSSPageFixtureProtocol.serve(host: host, contentType: "text/html", body: Data(body.utf8))
        defer { session.invalidateAndCancel(); RSSPageFixtureProtocol.remove(host: host) }
        var source = RSSSource(name: "Pages", url: "https://\(host)/")
        source.ruleArticles = "class.item"
        source.ruleTitle = "a@text"
        source.ruleLink = "a@href"
        source.searchUrl = "https://\(host)/search?word={{key}}&page={{page}}"
        source.ruleNextPage = "a.next@href@js:java.put('nextSeen','yes');result"
        source.ruleDescription = "@js:java.get('nextSeen')"
        let first = try await LegadoRSSScraper.fetchListPage(source: source, key: "needle", requestSession: session)
        #expect(first.nextURL == "https://\(host)/next")
        #expect(first.items.first?.contentHTML == "yes")
        #expect(first.items.first?.scope == .search("needle"))
        source.ruleNextPage = "PAGE"
        let second = try await LegadoRSSScraper.fetchListPage(source: source, page: 2, key: "needle", requestSession: session)
        #expect(second.nextURL == source.searchUrl)
        #expect(first.items.map(\.id) == second.items.map(\.id))
        let urls = RSSPageFixtureProtocol.requests(host: host).compactMap(\.url)
        #expect(urls.map(\.query) == ["word=needle&page=1", "word=needle&page=2"])
    }

    @Test("合法空列表和空Feed是成功结果，不是解析失败")
    func emptyPagesSucceed() async throws {
        let host = "rss-browse-\(UUID().uuidString.lowercased()).invalid"
        let session = RSSPageFixtureProtocol.makeSession()
        RSSPageFixtureProtocol.serve(host: host, sequences: [
            "/rules": [.init(body: Data("<main>No items</main>".utf8))],
            "/feed": [.init(body: Data("<rss version='2.0'><channel><title>Empty</title></channel></rss>".utf8))]
        ])
        defer { session.invalidateAndCancel(); RSSPageFixtureProtocol.remove(host: host) }
        var source = RSSSource(name: "Empty rules", url: "https://\(host)/rules")
        source.ruleArticles = "class.item"
        source.ruleTitle = "a@text"
        source.ruleLink = "a@href"
        let fetcher = RSSFetcher(session: session)
        await fetcher.fetchItems(from: source)
        #expect(fetcher.error == nil)
        guard case .updated(let items, _, _) = fetcher.response else { Issue.record("合法空列表没有成功响应"); return }
        #expect(items.isEmpty)
        await fetcher.fetchItems(from: RSSSource(name: "Empty feed", url: "https://\(host)/feed"))
        #expect(fetcher.error == nil)
        guard case .updated(let feedItems, _, _) = fetcher.response else { Issue.record("合法空Feed没有成功响应"); return }
        #expect(feedItems.isEmpty)
    }
}
