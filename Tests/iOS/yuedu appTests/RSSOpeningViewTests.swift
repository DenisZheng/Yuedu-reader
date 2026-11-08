import SwiftUI
import Testing
import UIKit
import WebKit
@testable import yuedu_app

@Suite("RSS opening views", .serialized)
@MainActor
struct RSSOpeningViewTests {
    @Test("规则文章无description/正文规则时自动打开原网页，而非调用普通全文抓取")
    func articleOriginalPage() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = RSSStore(storageDirectory: directory)
        let server = try VideoStillFixtureServer(directory: directory, routes: [
            "/article": .init(body: Data("<p id='value'>Original article</p>".utf8), requiredHeaders: ["x-source": "fixture"])
        ])
        let base = try await server.start()
        defer {
            server.stop()
            do { try FileManager.default.removeItem(at: directory) } catch { Issue.record(error) }
        }
        var source = RSSSource(name: "Original", url: base.appendingPathComponent("list").absoluteString)
        source.ruleArticles = "class.item"; source.header = #"{"X-Source":"fixture"}"#
        store.addSource(source)
        let item = RSSItem(id: "one", title: "Original", link: base.appendingPathComponent("article").absoluteString, sourceId: source.id)
        store.mergeFetchedItems([item], for: source.id)
        let window = try host(NavigationStack { RSSArticleReaderView(articleID: item.id, store: store) })
        defer { window.isHidden = true; window.rootViewController = nil }
        let deadline = ContinuousClock.now + .seconds(8)
        while find(WKWebView.self, in: window)?.url?.path != "/article", ContinuousClock.now < deadline { await Task.yield() }
        let web = try #require(find(WKWebView.self, in: window))
        while web.isLoading, ContinuousClock.now < deadline { await Task.yield() }
        #expect(try await web.evaluateJavaScript("document.getElementById('value').textContent") as? String == "Original article")
        #expect(server.requests.filter { $0.path == "/article" }.count == 1)
        #expect(store.article(id: item.id)?.fullTextHTML == nil)
        try await store.flushPersistence()
    }

    @Test("WebKit跨origin重定向不传播源私有头")
    func webRedirectIsolation() async throws {
        let destination = try VideoStillFixtureServer(directory: .temporaryDirectory, routes: [
            "/final": .init(body: Data("<p id='value'>Final</p>".utf8))
        ])
        let final = try await destination.start().appendingPathComponent("final")
        let origin = try VideoStillFixtureServer(directory: .temporaryDirectory, routes: [
            "/start": .init(body: Data(), status: "302 Found", headers: ["Location": final.absoluteString], requiredHeaders: ["x-source": "fixture"])
        ])
        let base = try await origin.start()
        defer { origin.stop(); destination.stop() }
        var source = RSSSource(name: "Redirect", url: base.appendingPathComponent("start").absoluteString)
        source.importedFromLegado = true; source.singleUrl = true
        source.header = #"{"X-Source":"fixture","Authorization":"Bearer fixture"}"#
        let target = try #require(try await RSSOpenTarget.resolve(source: source))
        var loading = true
        var error: String?
        let window = try host(RSSSourcePageWebView(source: source, target: target,
            error: Binding(get: { error }, set: { error = $0 }), loading: Binding(get: { loading }, set: { loading = $0 })))
        defer { window.isHidden = true; window.rootViewController = nil }
        let deadline = ContinuousClock.now + .seconds(8)
        while loading, ContinuousClock.now < deadline { await Task.yield() }
        #expect(!loading && error == nil)
        let request = try #require(destination.requests.first)
        #expect(request.headers["x-source"] == nil && request.headers["authorization"] == nil)
    }

    @Test("启动HTML由实际WebView加载，startJs遵守enableJs")
    func startupHTMLExecutesOnlyWhenEnabled() async throws {
        for enabled in [false, true] {
            var source = RSSSource(name: "Startup", url: "https://startup.invalid/")
            source.enableJs = enabled
            source.startJs = "document.getElementById('value').textContent='Started'"
            var error: String?
            var loading = true
            let view = RSSSourcePageWebView(source: source,
                target: .html("<p id='value'>Original</p>", baseURL: source.url),
                error: Binding(get: { error }, set: { error = $0 }),
                loading: Binding(get: { loading }, set: { loading = $0 }))
            let window = try host(view)
            defer { window.isHidden = true; window.rootViewController = nil }
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: .seconds(8))
            while loading, clock.now < deadline { await Task.yield() }
            #expect(!loading && error == nil)
            let web = try #require(find(WKWebView.self, in: window))
            #expect(try await web.evaluateJavaScript("document.getElementById('value').textContent") as? String == (enabled ? "Started" : "Original"))
        }
    }

    @Test("动态入口请求真正到达WebKit服务器，保留POST和源认证头")
    func sourceRequestReachesWebKit() async throws {
        let directory = FileManager.default.temporaryDirectory
        let server = try VideoStillFixtureServer(directory: directory, routes: [
            "/open": .init(body: Data("<p id='value'>Opened</p>".utf8), requiredHeaders: ["x-source": "fixture"], allowedMethods: ["POST"])
        ])
        let base = try await server.start()
        defer { server.stop() }
        var source = RSSSource(name: "Request", url: base.absoluteString)
        source.importedFromLegado = true; source.singleUrl = true
        source.sortUrl = base.appendingPathComponent("open").absoluteString + #",{"method":"POST","body":"a=1"}"#
        source.header = #"{"X-Source":"fixture"}"#
        let target = try #require(try await RSSOpenTarget.resolve(source: source))
        var loading = true
        var error: String?
        let window = try host(RSSSourcePageWebView(source: source, target: target,
            error: Binding(get: { error }, set: { error = $0 }), loading: Binding(get: { loading }, set: { loading = $0 })))
        defer { window.isHidden = true; window.rootViewController = nil }
        let deadline = ContinuousClock.now + .seconds(8)
        while loading, ContinuousClock.now < deadline { await Task.yield() }
        #expect(!loading && error == nil)
        let request = try #require(server.requests.first)
        #expect(request.method == "POST" && request.headers["x-source"] == "fixture")
        #expect(String(decoding: request.body, as: UTF8.self) == "a=1")
        #expect(server.requests.count == 1, "加载响应不得再次发送POST")
        let web = try #require(find(WKWebView.self, in: window))
        #expect(try await web.evaluateJavaScript("document.getElementById('value').textContent") as? String == "Opened")
    }

    @Test("原生搜索提交真正请求searchUrl，只展示查询作用域")
    func remoteSearchAction() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = RSSStore(storageDirectory: directory)
        let server = try VideoStillFixtureServer(directory: directory, routes: [
            "/list": .init(body: Data("<div class='item'><a href='/one'>Initial result</a></div>".utf8)),
            "/search/needle/1": .init(body: Data("<div class='item'><a href='/two'>Remote result</a></div>".utf8))
        ])
        let base = try await server.start()
        defer {
            server.stop()
            do { try FileManager.default.removeItem(at: directory) } catch { Issue.record(error) }
        }
        var source = RSSSource(name: "UI search", url: base.appendingPathComponent("list").absoluteString)
        source.searchUrl = base.absoluteString + "search/{{key}}/{{page}}"
        source.ruleArticles = "class.item"; source.ruleTitle = "a@text"; source.ruleLink = "a@href"
        store.addSource(source)
        let snapshot = source
        try await withAutomation {
            let window = try host(NavigationStack { RSSFeedView(source: snapshot, store: store) })
            defer { window.isHidden = true; window.rootViewController = nil }
            let deadline = ContinuousClock.now + .seconds(8)
            while (store.articles(for: source.id).isEmpty || find(UITextField.self, in: window) == nil),
                  ContinuousClock.now < deadline { await Task.yield() }
            let initial = try #require(store.articles(for: source.id).first)
            let field = try #require(find(UITextField.self, in: window))
            #expect(field.becomeFirstResponder())
            field.insertText("needle")
            #expect(field.text == "needle")
            // UITextField的原生Return主动作，交给SwiftUI安装的primaryActionTriggered目标。
            field.sendActions(for: .primaryActionTriggered)
            while store.articles(for: source.id, scope: .search("needle")).isEmpty,
                  ContinuousClock.now < deadline { await Task.yield() }
            let remote = try #require(store.articles(for: source.id, scope: .search("needle")).first)
            #expect(remote.title == "Remote result")
            while element("rss.article.\(remote.id)", in: window) == nil,
                  ContinuousClock.now < deadline { await Task.yield() }
            #expect(element("rss.article.\(remote.id)", in: window) != nil)
            #expect(element("rss.article.\(initial.id)", in: window) == nil)
            #expect(server.requests.map(\.path) == ["/list", "/search/needle/1"])
            #expect(server.requests.last?.headers["if-none-match"] == nil)
        }
        try await store.flushPersistence()
    }

    @Test("实际Feed页面的加载更多按钮追加第二页，而不是重复第一页")
    func feedLoadMoreAction() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = RSSStore(storageDirectory: directory)
        let server = try VideoStillFixtureServer(directory: directory, routes: [
            "/list/1": .init(body: Data("<div class='item'><a href='/one'>One</a></div>".utf8)),
            "/list/2": .init(body: Data("<div class='item'><a href='/two'>Two</a></div>".utf8))
        ])
        let base = try await server.start()
        defer {
            server.stop()
            do { try FileManager.default.removeItem(at: directory) } catch { Issue.record(error) }
        }
        var source = RSSSource(name: "UI pages", url: base.absoluteString + "list/{{page}}")
        source.ruleArticles = "class.item"; source.ruleTitle = "a@text"; source.ruleLink = "a@href"; source.ruleNextPage = "PAGE"
        store.addSource(source)
        let snapshot = source
        try await withAutomation {
            let window = try host(NavigationStack { RSSFeedView(source: snapshot, store: store) })
            defer { window.isHidden = true; window.rootViewController = nil }
            let deadline = ContinuousClock.now + .seconds(8)
            while element("rss.page.next", in: window) == nil, ContinuousClock.now < deadline { await Task.yield() }
            #expect(store.articles(for: source.id).count == 1)
            #expect(server.requests.map(\.path) == ["/list/1"])
            let button = try #require(element("rss.page.next", in: window))
            #expect(button.accessibilityActivate())
            while store.articles(for: source.id).count < 2, ContinuousClock.now < deadline { await Task.yield() }
            #expect(Set(store.articles(for: source.id).map(\.title)) == ["One", "Two"])
            #expect(server.requests.filter { $0.path.hasPrefix("/list/") }.map(\.path) == ["/list/1", "/list/2"])
        }
        try await store.flushPersistence()
    }

    private func host(_ view: some View) throws -> UIWindow {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: view)
        window.makeKeyAndVisible()
        return window
    }
    private func find<T: UIView>(_ type: T.Type, in view: UIView) -> T? {
        if let match = view as? T { return match }
        return view.subviews.lazy.compactMap { find(type, in: $0) }.first
    }
    private func element(_ id: String, in object: NSObject) -> NSObject? {
        if object.responds(to: NSSelectorFromString("accessibilityIdentifier")),
           object.value(forKey: "accessibilityIdentifier") as? String == id { return object }
        if let children = object.accessibilityElements as? [NSObject] {
            return children.lazy.compactMap { element(id, in: $0) }.first
        }
        return (object as? UIView)?.subviews.lazy.compactMap { element(id, in: $0) }.first
    }
    private func withAutomation(_ body: () async throws -> Void) async throws {
        let library = try #require(dlopen("/usr/lib/libAccessibility.dylib", RTLD_NOW))
        typealias Get = @convention(c) () -> Bool
        typealias Set = @convention(c) (Bool) -> Void
        let get = unsafeBitCast(try #require(dlsym(library, "_AXSAutomationEnabled")), to: Get.self)
        let set = unsafeBitCast(try #require(dlsym(library, "_AXSSetAutomationEnabled")), to: Set.self)
        let previous = get()
        set(true)
        defer { set(previous) }
        try await body()
    }
}
