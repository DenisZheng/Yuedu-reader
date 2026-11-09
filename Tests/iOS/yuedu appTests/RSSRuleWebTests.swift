import SwiftUI
import Testing
import UIKit
import WebKit
@testable import yuedu_app

/// 通过生产文章View验证规则网页，而不是只测HTML字符串或PoC WebView。
@Suite("RSS rule web documents", .serialized)
@MainActor
struct RSSRuleWebTests {
    @MainActor @Observable
    final class PageState {
        var source: RSSSource
        init(_ source: RSSSource) { self.source = source }
    }
    private struct MutablePage: View {
        let state: PageState
        @Binding var error: String?
        @Binding var loading: Bool
        var body: some View {
            RSSSourcePageWebView(source: state.source,
                target: .articleHTML("<p id='probe'>Original</p><script>window.pageRan=true</script>", baseURL: state.source.url),
                error: $error, loading: $loading)
        }
    }

    @Test("完成注入失败明确报错且不泄露异常文本；源开关变化取消旧脚本并重新加载")
    func scriptFailureAndConfigurationChange() async throws {
        var source = RSSSource(name: "Failure", url: "https://failure.invalid/")
        source.preloadJs = "window.preloadRan=true"
        source.injectJs = "throw new Error('synthetic-private-payload')"
        let state = PageState(source)
        var loading = true
        var error: String?
        let window = try host(MutablePage(state: state, error: Binding(get: { error }, set: { error = $0 }),
                                         loading: Binding(get: { loading }, set: { loading = $0 })))
        defer { close(window) }
        var deadline = ContinuousClock.now + .seconds(6)
        while loading, ContinuousClock.now < deadline { await Task.yield() }
        #expect(!loading && error == localized("來源網頁腳本執行失敗"))
        state.source.enableJs = false
        deadline = ContinuousClock.now + .seconds(6)
        while error != nil || loading, ContinuousClock.now < deadline { await Task.yield() }
        #expect(!loading && error == nil)
        let web = try await webView(in: window)
        #expect(try await web.evaluateJavaScript("typeof window.preloadRan") as? String == "undefined")
        #expect(try await web.evaluateJavaScript("typeof window.pageRan") as? String == "undefined")
    }

    @Test("启动页使用startStyle/startJs，文章CSS不覆盖启动CSS，baseURL开关实际生效")
    func startupStyleAndBase() async throws {
        for useBase in [true, false] {
            var source = RSSSource(name: "Startup", url: "https://startup.invalid/base/index")
            source.loadWithBaseUrl = useBase
            source.style = "#probe{color:rgb(99,99,99)}"
            source.startStyle = "#probe{color:rgb(17,34,51)}"
            source.preloadJs = "window.trace=['preload'];"
            source.startJs = "window.trace.push('startup');"
            source.injectJs = "window.trace.push('finished');"
            var loading = true
            var error: String?
            let window = try host(RSSSourcePageWebView(source: source,
                target: .html("<body><script>window.trace.push('page')</script><p id='probe'>Startup</p><a id='link' href='child'>Child</a></body>", baseURL: source.url),
                error: Binding(get: { error }, set: { error = $0 }),
                loading: Binding(get: { loading }, set: { loading = $0 })))
            defer { close(window) }
            let deadline = ContinuousClock.now + .seconds(6)
            while loading, ContinuousClock.now < deadline { await Task.yield() }
            #expect(!loading && error == nil)
            let web = try await webView(in: window)
            #expect(try await web.evaluateJavaScript("window.trace.join('|')") as? String == "preload|page|startup|finished")
            #expect(try await web.evaluateJavaScript("getComputedStyle(document.getElementById('probe')).color") as? String == "rgb(17, 34, 51)")
            #expect(try await web.evaluateJavaScript("document.baseURI") as? String == (useBase ? source.url : "about:blank"))
        }
    }

    @Test("禁用页面JS时仍恢复和保存规则文章滚动位置，重建store不丢进度")
    func nativeScrollProgress() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = RSSStore(storageDirectory: directory)
        defer { do { try FileManager.default.removeItem(at: directory) } catch { Issue.record(error) } }
        var source = RSSSource(name: "Scroll", url: "https://scroll.invalid/")
        source.ruleArticles = "class.item"; source.enableJs = false
        store.addSource(source)
        let item = RSSItem(id: "scroll", title: "Scroll", link: "https://scroll.invalid/article",
                           contentHTML: "<p id='probe' style='height:6000px'>Long document</p>", sourceId: source.id)
        store.mergeFetchedItems([item], for: source.id)
        store.updateReaderScrollY(articleId: item.id, scrollY: 300)
        let window = try host(NavigationStack { RSSArticleReaderView(articleID: item.id, store: store) })
        defer { close(window) }
        let web = try await webView(in: window)
        let deadline = ContinuousClock.now + .seconds(5)
        while web.scrollView.contentOffset.y < 290, ContinuousClock.now < deadline { await Task.yield() }
        #expect(abs(web.scrollView.contentOffset.y - 300) < 2)
        web.scrollView.setContentOffset(CGPoint(x: 0, y: 600), animated: false)
        web.scrollView.delegate?.scrollViewDidEndDragging?(web.scrollView, willDecelerate: false)
        while store.article(id: item.id)?.readerScrollY != 600, ContinuousClock.now < deadline { await Task.yield() }
        #expect(store.article(id: item.id)?.readerScrollY == 600)
        try await store.flushPersistence()
        #expect(RSSStore(storageDirectory: directory).article(id: item.id)?.readerScrollY == 600)
    }

    @Test("规则description保留交互与iframe；preload、页面和finished分阶段执行且不向子frame注入")
    func interactiveDescription() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = RSSStore(storageDirectory: directory)
        let server = try VideoStillFixtureServer(directory: directory, routes: [
            "/frame": .init(body: Data("<p>Child</p>".utf8))
        ])
        let base = try await server.start()
        defer {
            server.stop()
            do { try FileManager.default.removeItem(at: directory) } catch { Issue.record(error) }
        }
        var source = RSSSource(name: "Rule web", url: base.appendingPathComponent("list").absoluteString)
        source.ruleArticles = "class.item"
        source.preloadJs = "window.trace=['preload'];window.preloadMark='main';"
        source.injectJs = "window.trace.push('finished');"
        source.startJs = "window.trace.push('startup-must-not-run');"
        source.style = "#probe{color:rgb(17,34,51)}"
        store.addSource(source)
        let html = """
        <html><head><script>window.trace=(window.trace||[]).concat('page');</script></head>
        <body><button id='probe' onclick="this.textContent='Clicked'">Go</button><iframe id='child' src='frame'></iframe></body></html>
        """
        let item = RSSItem(id: "interactive", title: "Rule", link: base.appendingPathComponent("article").absoluteString,
                           contentHTML: html, sourceId: source.id)
        store.mergeFetchedItems([item], for: source.id)
        let window = try host(NavigationStack { RSSArticleReaderView(articleID: item.id, store: store) })
        defer { close(window) }
        let web = try await webView(in: window)
        let deadline = ContinuousClock.now + .seconds(6)
        // 等待本用例的finished脚本结果，不能把WebView实例出现或isLoading=false当作注入已完成。
        while (try await web.evaluateJavaScript("(window.trace||[]).includes('finished')") as? Bool) != true,
              ContinuousClock.now < deadline { await Task.yield() }
        while !server.requests.contains(where: { $0.path == "/frame" }), ContinuousClock.now < deadline { await Task.yield() }
        #expect(try await web.evaluateJavaScript("document.getElementById('probe') !== null") as? Bool == true)
        #expect(try await web.evaluateJavaScript("(window.trace||[]).join('|')") as? String == "preload|page|finished")
        #expect(try await web.evaluateJavaScript("getComputedStyle(document.getElementById('probe')).color") as? String == "rgb(17, 34, 51)")
        #expect(try await web.evaluateJavaScript("document.getElementById('child').contentWindow.preloadMark === undefined") as? Bool == true)
        _ = try await web.evaluateJavaScript("document.getElementById('probe').click()")
        #expect(try await web.evaluateJavaScript("document.getElementById('probe').textContent") as? String == "Clicked")
        #expect(server.requests.contains { $0.path == "/frame" })
        #expect(!server.requests.contains { $0.path == "/article" }, "description优先，不抓取原页")
        try await store.flushPersistence()
    }

    @Test("规则网页enableJs=false关闭页面/源脚本，但保留HTML与源样式")
    func disabledScripts() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = RSSStore(storageDirectory: directory)
        defer { do { try FileManager.default.removeItem(at: directory) } catch { Issue.record(error) } }
        var source = RSSSource(name: "Disabled", url: "https://disabled.invalid/")
        source.ruleArticles = "class.item"
        source.enableJs = false
        source.preloadJs = "window.ran='preload'"
        source.injectJs = "window.ran='finished'"
        source.style = "#probe{color:rgb(17,34,51)}"
        store.addSource(source)
        let item = RSSItem(id: "disabled", title: "Disabled", link: "https://disabled.invalid/article", contentHTML: "<button id='probe' onclick=\"this.textContent='Wrong'\">Go</button><script>window.ran='page'</script>", sourceId: source.id)
        store.mergeFetchedItems([item], for: source.id)
        let window = try host(NavigationStack { RSSArticleReaderView(articleID: item.id, store: store) })
        defer { close(window) }
        let web = try await webView(in: window)
        #expect(try await web.evaluateJavaScript("document.getElementById('probe') !== null") as? Bool == true)
        #expect(try await web.evaluateJavaScript("typeof window.ran") as? String == "undefined")
        #expect(try await web.evaluateJavaScript("getComputedStyle(document.getElementById('probe')).color") as? String == "rgb(17, 34, 51)")
        _ = try await web.evaluateJavaScript("document.getElementById('probe').click()")
        #expect(try await web.evaluateJavaScript("document.getElementById('probe').textContent") as? String == "Go")
        try await store.flushPersistence()
    }

    @Test("普通Feed即使来自Legado导入仍保留安全文章路径，不执行原始脚本/iframe")
    func ordinaryFeedStaysSafe() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = RSSStore(storageDirectory: directory)
        defer { do { try FileManager.default.removeItem(at: directory) } catch { Issue.record(error) } }
        var source = RSSSource(name: "Feed", url: "https://safe-feed.invalid/")
        source.importedFromLegado = true
        store.addSource(source)
        let html = "<p>Feed</p><script>window.ran='unsafe'</script><button onclick=\"window.ran='button'\">Go</button><iframe src='about:blank'></iframe>"
        let item = RSSItem(id: "safe", title: "Feed", link: "https://safe-feed.invalid/article", contentHTML: html, sourceId: source.id)
        store.mergeFetchedItems([item], for: source.id)
        store.updateFullText(articleId: item.id, text: "Feed", html: html)
        let window = try host(NavigationStack { RSSArticleReaderView(articleID: item.id, store: store) })
        defer { close(window) }
        let web = try await webView(in: window)
        #expect(try await web.evaluateJavaScript("typeof window.ran") as? String == "undefined")
        #expect(try await web.evaluateJavaScript("document.querySelectorAll('iframe,button').length") as? Int == 0)
        try await store.flushPersistence()
    }

    private func host(_ view: some View) throws -> UIWindow {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: view)
        window.makeKeyAndVisible()
        return window
    }
    private func close(_ window: UIWindow) { window.isHidden = true; window.rootViewController = nil }
    private func webView(in window: UIWindow) async throws -> WKWebView {
        func find(_ view: UIView) -> WKWebView? {
            (view as? WKWebView) ?? view.subviews.lazy.compactMap(find).first
        }
        let deadline = ContinuousClock.now + .seconds(6)
        while (find(window) == nil || find(window)?.url == nil || find(window)?.isLoading == true),
              ContinuousClock.now < deadline { await Task.yield() }
        let web = try #require(find(window))
        while (try await web.evaluateJavaScript("document.readyState") as? String) != "complete",
              ContinuousClock.now < deadline { await Task.yield() }
        return web
    }
}
