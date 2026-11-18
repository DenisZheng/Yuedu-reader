import Foundation
import Testing
@testable import yuedu_app

@Suite("RSS普通Feed全文请求上下文", .serialized)
@MainActor
struct RSSArticleFullTextRequestTests {
    @Test("全文使用调用方会话及源动态请求头，并回写唯一文章owner")
    func sourceHeadersAndSessionReachFullText() async throws {
        let directory = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = RSSStore(storageDirectory: directory)
        let session = RSSPageFixtureProtocol.makeSession()
        let host = "127.0.0.1"
        let path = "/full-" + UUID().uuidString
        RSSPageFixtureProtocol.serve(host: host, contentType: "text/html", body: Data("<article><p>\(String(repeating: "固定全文内容。", count: 80))</p></article>".utf8))
        defer {
            session.invalidateAndCancel()
            RSSPageFixtureProtocol.remove(host: host)
            do { try FileManager.default.removeItem(at: directory) } catch { Issue.record(error) }
        }
        var source = RSSSource(name: "Full text fixture", url: "https://\(host):9/feed")
        source.singleUrl = false
        source.jsLib = "function fixtureHeader(){return 'fixture-title'}"
        source.header = #"@js:JSON.stringify({'X-Full-Text':fixtureHeader()})"#
        store.addSource(source)
        let item = RSSItem(id: "full", title: "fixture-title", link: "https://\(host):9\(path)", sourceId: source.id)
        store.mergeFetchedItems([item], for: source.id)
        let article = try #require(store.article(id: item.id))
        #expect(!RSSArticleContentService.usesRules(source))
        _ = try await RSSArticleContentService.load(article, source: source, store: store, session: session)
        let requests = RSSPageFixtureProtocol.requests(host: host)
        #expect(requests.count == 1)
        #expect(requests.first?.value(forHTTPHeaderField: "X-Full-Text") == "fixture-title")
        #expect(requests.first?.url?.path == path)
        #expect(store.article(id: item.id)?.fullText?.contains("固定全文内容") == true)
        try await store.flushPersistence()
    }

    @Test("普通Feed链接中的模板只当字面量，不执行其中的源表达式")
    func feedLinksDoNotBecomeScripts() async throws {
        let directory = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = RSSStore(storageDirectory: directory)
        defer { do { try FileManager.default.removeItem(at: directory) } catch { Issue.record(error) } }
        var source = RSSSource(name: "Literal feed", url: "https://literal-feed.invalid/feed")
        source.singleUrl = false
        store.addSource(source)
        let item = RSSItem(id: "literal", title: "Literal", link: "https://literal-feed.invalid/article?x={{source.put('unexpected','yes')}}", sourceId: source.id)
        store.mergeFetchedItems([item], for: source.id)
        let target = try await RSSOpenTarget.originalArticle(try #require(store.article(id: item.id)), source: source,
                                                           owner: store, interpretsRuleURL: false)
        guard case .request(let request, _) = target else { Issue.record("没有准备普通文章请求"); return }
        #expect(request.url?.absoluteString.contains("{{") == false)
        #expect(store.variables(for: source.id)["unexpected"] == nil)
        try await store.flushPersistence()
    }

    @Test("全文跨origin重定向不带源私有头，正文相对链接按最终URL解析")
    func redirectsKeepHeadersScopedAndFinalBase() async throws {
        let destination = try VideoStillFixtureServer(directory: .temporaryDirectory, routes: [
            "/final/article": .init(body: Data("<article><p>\(String(repeating: "固定目标正文。", count: 80))</p><p><a href='next'>Next</a></p></article>".utf8), type: "text/html")
        ])
        let final = try await destination.start().appendingPathComponent("final/article")
        let origin = try VideoStillFixtureServer(directory: .temporaryDirectory, routes: [
            "/redirect": .init(body: Data(), status: "302 Found", headers: ["Location": final.absoluteString], requiredHeaders: ["x-full-text": "scoped"])
        ])
        let base = try await origin.start()
        defer { origin.stop(); destination.stop() }
        var source = RSSSource(name: "Redirect feed", url: base.appendingPathComponent("feed").absoluteString)
        source.singleUrl = false
        source.header = #"{"X-Full-Text":"scoped","Authorization":"Bearer synthetic"}"#
        let item = RSSItem(id: "redirect", title: "Redirect", link: base.appendingPathComponent("redirect").absoluteString, sourceId: source.id)
        let article = RSSArticleRecord(item: item)
        let result = try await RSSArticleContentLoader.loadFullText(for: article, source: source)
        #expect(destination.requests.first?.headers["x-full-text"] == nil)
        #expect(destination.requests.first?.headers["authorization"] == nil)
        #expect(result.html.contains(final.deletingLastPathComponent().appendingPathComponent("next").upgradedToHTTPS().absoluteString))
    }
}
