import Foundation
import JavaScriptCore
import Testing
@testable import yuedu_app

/// 固定覆盖原生字符串跨VM的拼接与RSS会话重建。原生API用例仅用于区分平台故障，
/// 生产请求仍通过RSSRuntime/JSCoreEngine；参见Technotes/RSSJSCContextLifetimeCrash.md。
@Suite("RSS article script object", .serialized)
struct RSSArticleScriptObjectTests {
    @MainActor
    @Test("撤销后重建同源会话，文章字段与变量重复100次不丢失")
    func freshSessions() async throws {
        let session = RSSPageFixtureProtocol.makeSession()
        let host = "rss-strings-\(UUID().uuidString.lowercased()).invalid"
        RSSPageFixtureProtocol.serve(host: host, contentType: "text/html", body: Data("<p>Body</p>".utf8))
        defer { session.invalidateAndCancel(); RSSPageFixtureProtocol.remove(host: host) }
        for _ in 0..<100 {
            var source = RSSSource(name: "New session", url: "https://\(host)/")
            source.ruleContent = "@js: rssArticle.title + '|' + java.get('marker')"
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer {
                do { try FileManager.default.removeItem(at: directory) }
                catch { Issue.record("测试目录清理失败") }
            }
            let store = RSSStore(storageDirectory: directory)
            store.addSource(source)
            let prior = try await RSSRuntime.make(source: source, owner: store, requestSession: session)
            _ = try await prior.run { host in await host.run { $0.evaluateSourceScript("'prior'") } }
            prior.session.invalidate()
            let text = try await LegadoRSSScraper.fetchArticleContent(source: source, articleLink: "https://\(host)/b", owner: store,
                variables: ["marker": "B"], articleTitle: "B", requestSession: session)
            #expect(text == "B|B")
            try await store.flushPersistence()
        }
    }

    @Test("纯JavaScriptCore跨context原生文章字符串")
    func nativeContextReplacement() async throws {
        try await SourceScriptThread.run {
            for _ in 0..<100 {
                var previous: JSContext? = JSContext()
                _ = previous?.evaluateScript("'prior'")
                let current = JSContext()!
                previous = nil
                current.setObject(["title": "B"], forKeyedSubscript: "rssArticle" as NSString)
                current.setObject("B", forKeyedSubscript: "marker" as NSString)
                #expect(current.evaluateScript("rssArticle.title+'|'+marker")?.toString() == "B|B")
            }
        }
    }

    @Test("跨实例上下文回收后的原生字符串连接")
    func contextReplacement() async throws {
        try await SourceScriptThread.run {
            let source = RSSSource(name: "Article fixture", url: "https://article.invalid")
            for _ in 0..<100 {
                var previous: JSCoreEngine? = JSCoreEngine()
                _ = previous?.evaluate("'prior'")
                let current = JSCoreEngine()
                current.getData = { _ in "B" }
                previous = nil
                let article = RSSArticleScriptObject(source: source, sortName: "", data: RuleData())
                article.title = "B"
                #expect(current.evaluate("rssArticle.title+'|'+java.get('marker')", bindings: ["rssArticle": article]) == "B|B")
            }
        }
    }

    @Test("原生文章字段与java.get连接后可稳定转换为Swift String")
    func concatenation() async throws {
        try await SourceScriptThread.run {
            let source = RSSSource(name: "Article fixture", url: "https://article.invalid")
            let engine = JSCoreEngine()
            engine.getData = { _ in "B" }
            for _ in 0..<100 {
                let article = RSSArticleScriptObject(source: source, sortName: "", data: RuleData())
                article.title = "B"
                #expect(engine.evaluate("rssArticle.title+'|'+java.get('marker')", bindings: ["rssArticle": article]) == "B|B")
            }
            let bridge = ModernParserBridge(source: RSSRuntime.scriptSource(source))
            for _ in 0..<100 {
                let data = RuleData()
                data.variableMap = ["marker": "B"]
                let article = RSSArticleScriptObject(source: source, sortName: "", data: data)
                article.title = "B"
                let text = try bridge.withRuleContext(content: "<p>Body</p>", baseURL: source.url, scope: data, bindings: ["rssArticle": article]) {
                    $0.getString(ruleStr: "@js:rssArticle.title+'|'+java.get('marker')")
                }
                #expect(text == "B|B")
            }
        }
    }
}
