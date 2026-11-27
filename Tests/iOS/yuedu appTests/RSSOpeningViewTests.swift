import SwiftUI
import Testing
import UIKit
import WebKit
@testable import yuedu_app

@Suite("RSS opening views", .serialized)
@MainActor
struct RSSOpeningViewTests {
    @Test("分类首请求 503 与可用的源根网页相互独立，重试仍请求原分类")
    func unavailableCategoryDoesNotUseHomepageAsItsList() async throws {
        let directory = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = RSSStore(storageDirectory: directory)
        let session = RSSPageFixtureProtocol.makeSession()
        let hostname = "category-\(UUID().uuidString.lowercased()).invalid"
        let base = try #require(URL(string: "https://\(hostname)/"))
        let firstPage = base.appending(path: "page/1", directoryHint: .isDirectory)
        let unavailable = RSSPageFixtureProtocol.Response(body: Data("<p>Temporarily unavailable</p>".utf8), status: 503)
        RSSPageFixtureProtocol.serve(host: hostname, sequences: [
            firstPage.path: [unavailable, unavailable],
            "/": [.init(body: Data("<p>Available website</p>".utf8))]
        ])
        defer {
            session.invalidateAndCancel(); RSSPageFixtureProtocol.remove(host: hostname)
            do { try FileManager.default.removeItem(at: directory) } catch { Issue.record(error) }
        }
        var source = RSSSource(name: "Category and website fixture", url: base.absoluteString)
        source.importedFromLegado = true
        source.sortUrl = "首页::page/{{page}}/\n其他::/category/"
        source.ruleArticles = "class.item"; source.ruleTitle = "tag.a@text"; source.ruleLink = "tag.a@href"
        store.addSource(source)
        let feed = RSSFeedSession(source: source, store: store, session: session)
        await feed.refresh()
        #expect(feed.error == ScraperError.httpStatus(503).localizedDescription)
        #expect(feed.currentPage == 0 && feed.canRetry)
        #expect(RSSPageFixtureProtocol.requests(host: hostname).map(\.url) == [firstPage])

        let fallback = try #require(feed.webPageFallbackURL)
        #expect(fallback.url == base)
        let document = try await RSSOpenTarget.loadDocument(URLRequest(url: fallback.url), source: source, owner: store, session: session)
        #expect(document.statusCode == 200 && String(decoding: document.data, as: UTF8.self) == "<p>Available website</p>")
        await feed.retry()
        #expect(RSSPageFixtureProtocol.requests(host: hostname).map(\.url) == [firstPage, base, firstPage])
        #expect(feed.error == ScraperError.httpStatus(503).localizedDescription)
        #expect(store.articles(for: source.id).isEmpty)
        try await store.flushPersistence()
    }

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

    @Test("实际Feed页面加载第二页、打开内容后返回，应保留条目并继续第三页")
    func feedLoadMoreAction() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = RSSStore(storageDirectory: directory)
        let server = try VideoStillFixtureServer(directory: directory, routes: [
            "/list/1": .init(body: Data("<div class='item'><a href='/one'>One</a></div><a class='next' href='/list/2'>Next</a>".utf8)),
            "/list/2": .init(body: Data("<div class='item'><a href='/two'>Two</a></div><a class='next' href='/list/3'>Next</a>".utf8)),
            "/list/3": .init(body: Data("<div class='item'><a href='/three'>Three</a></div>".utf8)),
            "/two": .init(body: Data("<p id='watch'>Page two content</p>".utf8))
        ])
        // 第一次预取第3页收到503，暂停自动预取，返回后必须能从原页重试。
        server.route { [weak server] request in
            guard request.path == "/list/3", server?.requests.filter({ $0.path == "/list/3" }).count == 1 else { return nil }
            return .init(body: Data(), status: "503 Service Unavailable")
        }
        let base = try await server.start()
        defer {
            server.stop()
            do { try FileManager.default.removeItem(at: directory) } catch { Issue.record(error) }
        }
        var source = RSSSource(name: "UI pages", url: base.absoluteString + "list/{{page}}")
        source.ruleArticles = "class.item"; source.ruleTitle = "a@text"; source.ruleLink = "a@href"; source.ruleNextPage = "class.next@href"
        store.addSource(source)
        let snapshot = source
        try await withAutomation {
            let window = try host(NavigationStack { RSSFeedView(source: snapshot, store: store) })
            defer { window.isHidden = true; window.rootViewController = nil }
            let deadline = ContinuousClock.now + .seconds(8)
            while element("rss.page.retry", in: window) == nil, ContinuousClock.now < deadline {
                if let button = element("rss.page.next", in: window) { _ = button.accessibilityActivate() }
                await Task.yield()
            }
            try #require(element("rss.page.retry", in: window) != nil)
            try #require(server.requests.filter { $0.path.hasPrefix("/list/") }.map(\.path) == ["/list/1", "/list/2", "/list/3"])

            let second = try #require(store.articles(for: source.id).first { $0.title == "Two" })
            let id = "rss.article.\(second.id)"
            let openDeadline = ContinuousClock.now + .seconds(8)
            while element(id, in: window) == nil, ContinuousClock.now < openDeadline { await Task.yield() }
            #expect(try #require(element(id, in: window)).accessibilityActivate())
            while find(WKWebView.self, in: window)?.url?.path != "/two", ContinuousClock.now < openDeadline { await Task.yield() }
            let web = try #require(find(WKWebView.self, in: window))
            while web.isLoading, ContinuousClock.now < openDeadline { await Task.yield() }
            #expect(try await web.evaluateJavaScript("document.getElementById('watch').textContent") as? String == "Page two content")
            let navigation = try #require(findNavigation(in: window.rootViewController))
            try #require(navigation.popViewController(animated: false) != nil)

            let returnDeadline = ContinuousClock.now + .seconds(8)
            while element("rss.page.retry", in: window) == nil, ContinuousClock.now < returnDeadline { await Task.yield() }
            #expect(element(id, in: window) != nil, "返回后第2页的条目必须仍然可见")
            let retry = try #require(element("rss.page.retry", in: window))
            #expect(retry.accessibilityActivate())
            while !store.articles(for: source.id).contains(where: { $0.title == "Three" }), ContinuousClock.now < returnDeadline {
                await Task.yield()
            }
            #expect(Set(store.articles(for: source.id).map(\.title)) == ["One", "Two", "Three"])
            #expect(server.requests.filter { $0.path.hasPrefix("/list/") }.map(\.path) == ["/list/1", "/list/2", "/list/3", "/list/3"],
                    "返回不应重抓第一页，应直接重试第三页")
        }
        try await store.flushPersistence()
    }

    @Test("WebKit资源黑名单含非捕获分支时，正文和允许资源照常加载，命中的子资源不发送请求")
    func resourceRegexAlternation() async throws {
        let allowed = Data("#value{color:rgb(1, 2, 3)}".utf8)
        let blocked = Data("#value{color:red}".utf8)
        let body = """
            <link rel='stylesheet' href='/allowed.css'>
            <link rel='stylesheet' href='/blocked-one.css'>
            <link rel='stylesheet' href='/blocked-two-extra.css'>
            <p id='value'>Rendered fixture</p>
            """
        let server = try VideoStillFixtureServer(directory: .temporaryDirectory, routes: [
            "/page": .init(body: Data(body.utf8)),
            "/allowed.css": .init(body: allowed, type: "text/css"),
            "/blocked-one.css": .init(body: blocked, type: "text/css"),
            "/blocked-two-extra.css": .init(body: blocked, type: "text/css")
        ])
        let url = try await server.start().appendingPathComponent("page")
        defer { server.stop() }
        var source = RSSSource(name: "Safe filter fixture", url: url.absoluteString)
        source.importedFromLegado = true
        source.singleUrl = true
        source.contentBlacklist = #".*(?:blocked-one\.css|blocked-two.*\.css).*"#
        let target = try #require(try await RSSOpenTarget.resolve(source: source))
        var loading = true
        var error: String?
        let window = try host(RSSSourcePageWebView(source: source, target: target,
            error: Binding(get: { error }, set: { error = $0 }), loading: Binding(get: { loading }, set: { loading = $0 })))
        defer { window.isHidden = true; window.rootViewController = nil }
        let deadline = ContinuousClock.now + .seconds(8)
        while loading, ContinuousClock.now < deadline { await Task.yield() }
        try #require(!loading && error == nil, "\(error ?? "WebKit未加载")")
        let web = try #require(find(WKWebView.self, in: window))
        let rendered = try await web.evaluateJavaScript("[document.getElementById('value').textContent, getComputedStyle(document.getElementById('value')).color]") as? [String]
        #expect(rendered == ["Rendered fixture", "rgb(1, 2, 3)"])
        #expect(server.requests.map(\.path) == ["/page", "/allowed.css"])
    }

    private func findNavigation(in controller: UIViewController?) -> UINavigationController? {
        if let navigation = controller as? UINavigationController { return navigation }
        return controller?.children.lazy.compactMap { findNavigation(in: $0) }.first
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
