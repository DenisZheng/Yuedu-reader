import SwiftUI
import Testing
import UIKit
import WebKit
@testable import yuedu_app

/// 自建页面检验浏览器HTTP会话连续性；不连接Cloudflare、不生成或求解真人验证。
@Suite("RSS native browser session", .serialized)
@MainActor
struct RSSBrowserSessionTests {
    @Observable final class State {
        var loading = true
        var error: String?
    }

    @Test("普通singleUrl从浏览器发起并在原会话完成表单，保留来源、UA、Cookie与DOM存储",
          arguments: [(false, true), (true, true), (false, false)])
    func documentAndPostShareBrowserSession(directWebKitControl: Bool, customUserAgent: Bool) async throws {
        let cookie = "fixture" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let userAgent = customUserAgent ? "ReaderBrowserSessionFixture/1" : nil
        var requiredHeaders = ["cookie": cookie + "=scoped"]
        if let userAgent { requiredHeaders["user-agent"] = userAgent }
        let firstHTML = """
        <!doctype html><html><body><p id="ready">ready</p>
        <script>
        window.storageReady = false;
        try { sessionStorage.setItem('flow','same-session'); localStorage.setItem('fixture','yes'); window.storageReady = true; }
        catch(e) { window.storageReady = false; }
        </script>
        <form id="flow" method="POST" action="/done"><input name="fixture" value="submitted"></form>
        </body></html>
        """
        let finalHTML = """
        <!doctype html><html><body><p id="done">done</p><script>
        window.flowRecovered = sessionStorage.getItem('flow');
        window.storageRecovered = localStorage.getItem('fixture');
        </script></body></html>
        """
        let server = try VideoStillFixtureServer(directory: .temporaryDirectory, routes: [
            "/start": .init(body: Data(firstHTML.utf8), type: "text/html", status: "403 Forbidden",
                headers: ["Set-Cookie": cookie + "=scoped; Path=/; HttpOnly", "Cache-Control": "no-store"]),
            "/done": .init(body: Data(finalHTML.utf8), type: "text/html",
                requiredHeaders: requiredHeaders, allowedMethods: ["POST"])
        ])
        let base = try await server.start()
        defer { server.stop(); CookieStore.shared.remove(url: base.absoluteString, key: cookie) }
        var source = RSSSource(name: "Browser session fixture", url: base.appendingPathComponent("start").absoluteString)
        source.importedFromLegado = true
        source.singleUrl = true
        source.cacheFirst = false
        source.enabledCookieJar = true
        source.header = userAgent.map { "{\"User-Agent\":\"" + $0 + "\"}" } ?? "{}"
        source.enableJs = true
        let target = try #require(try await RSSOpenTarget.resolve(source: source))
        let state = State()
        let window: UIWindow?
        let control: RSSPoCWebPage?
        let web: WKWebView
        if directWebKitControl {
            let configuration = WKWebViewConfiguration()
            configuration.websiteDataStore = .nonPersistent()
            let page = try RSSPoCWebPage(configuration: configuration)
            control = page; window = nil; web = page.view
            web.customUserAgent = userAgent
            try await page.waiter.load { web.load(URLRequest(url: base.appendingPathComponent("start"))) }
            state.loading = false
        } else {
            control = nil
            let hosted = try host(RSSSourcePageWebView(source: source, target: target,
                error: Binding(get: { state.error }, set: { state.error = $0 }),
                loading: Binding(get: { state.loading }, set: { state.loading = $0 })))
            window = hosted
            let firstDeadline = ContinuousClock.now + .seconds(8)
            while state.loading, ContinuousClock.now < firstDeadline { await Task.yield() }
            try #require(!state.loading)
            web = try #require(findWeb(hosted))
        }
        defer { window?.isHidden = true; window?.rootViewController = nil; control?.close() }
        #expect(try await web.evaluateJavaScript("location.protocol") as? String == "http:")
        #expect(try await web.evaluateJavaScript("location.href") as? String == source.url)
        #expect(try await web.evaluateJavaScript("window.storageReady") as? Bool == true)
        let effectiveUserAgent = try #require(try await web.evaluateJavaScript("navigator.userAgent") as? String)
        if let userAgent { #expect(effectiveUserAgent == userAgent) }
        else { #expect(effectiveUserAgent.contains("AppleWebKit/")) }
        #expect(server.requests.first?.headers["user-agent"] == effectiveUserAgent)
        #expect(server.requests.filter { $0.path == "/start" }.count == 1)
        #expect(server.requests.first?.headers["sec-fetch-mode"] == "navigate", "首文档必须真实浏览器导航，不能仅将原生取得的HTML灌入浏览器")
        _ = try await web.evaluateJavaScript("document.getElementById('flow').submit(); void 0")
        let deadline = ContinuousClock.now + .seconds(8)
        while ContinuousClock.now < deadline {
            if web.url?.path == "/done", !web.isLoading, !state.loading { break }
            await Task.yield()
        }
        let posted = try #require(server.requests.first { $0.path == "/done" },
                                 "网页自身的POST必须由浏览器送达，不能被cancel→URLSession丢失body")
        #expect(posted.method == "POST")
        #expect(String(decoding: posted.body, as: UTF8.self) == "fixture=submitted")
        #expect(posted.headers["cookie"]?.contains(cookie + "=scoped") == true)
        #expect(posted.headers["user-agent"] == effectiveUserAgent)
        #expect(posted.headers["referer"] == source.url)
        #expect(posted.headers["sec-fetch-mode"] == "navigate", "后续表单仍由同一个浏览器发出")
        #expect(server.requests.filter { $0.path == "/done" }.count == 1)
        #expect(web.url?.path == "/done" && state.error == nil && !state.loading)
        #expect(try await web.evaluateJavaScript("document.getElementById('done').textContent") as? String == "done")
        #expect(try await web.evaluateJavaScript("window.flowRecovered") as? String == "same-session")
        #expect(try await web.evaluateJavaScript("window.storageRecovered") as? String == "yes")
    }

    @Test("网页返回回到首页，不关闭页面容器或重发子页请求", arguments: [false, true])
    func webHistoryBackReturnsToPreviousDocument(sharedExecutor: Bool) async throws {
        let root = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let requiredHeaders = sharedExecutor ? ["x-history": "fixture"] : [:]
        let server = try VideoStillFixtureServer(directory: root, routes: [
            "/home": .init(body: Data("<p id='page'>Home</p><a id='child' href='/child'>Open child</a>".utf8), requiredHeaders: requiredHeaders),
            "/child": .init(body: Data("<p id='page'>Child</p>".utf8), requiredHeaders: requiredHeaders)
        ])
        let base = try await server.start()
        defer {
            server.stop()
            if FileManager.default.fileExists(atPath: root.path) {
                do { try FileManager.default.removeItem(at: root) } catch { Issue.record(error) }
            }
        }
        var source = RSSSource(name: "Browser history fixture", url: base.appendingPathComponent("home").absoluteString)
        source.importedFromLegado = true
        source.singleUrl = true
        source.cacheFirst = false
        source.enabledCookieJar = true
        source.header = sharedExecutor ? #"{"X-History":"fixture"}"# : "{}"
        source.preloadJs = sharedExecutor ? "window.readHistoryFixture=()=>source.get('unused');" : nil
        let target = try #require(try await RSSOpenTarget.resolve(source: source))
        let state = State()
        let webNavigation = RSSWebNavigationState()
        let hosted = try host(RSSSourcePageWebView(source: source, target: target,
            error: Binding(get: { state.error }, set: { state.error = $0 }),
            loading: Binding(get: { state.loading }, set: { state.loading = $0 }),
            webNavigation: webNavigation))
        defer { hosted.isHidden = true; hosted.rootViewController = nil }
        let deadline = ContinuousClock.now + .seconds(8)
        while state.loading, ContinuousClock.now < deadline { await Task.yield() }
        try #require(!state.loading && state.error == nil)
        let web = try #require(findWeb(hosted))
        #expect(!webNavigation.canGoBack)
        #expect(server.requests.count == 1)
        #expect((server.requests[0].headers["sec-fetch-mode"] == "navigate") == !sharedExecutor)

        _ = try await web.evaluateJavaScript("document.getElementById('child').click(); void 0")
        let childDeadline = ContinuousClock.now + .seconds(8)
        while (web.url?.path != "/child" || web.isLoading || !webNavigation.canGoBack), ContinuousClock.now < childDeadline {
            await Task.yield()
        }
        try #require(web.url?.path == "/child" && !web.isLoading && webNavigation.canGoBack)
        #expect(try await web.evaluateJavaScript("document.getElementById('page').textContent") as? String == "Child")
        #expect(server.requests.count == 2)
        #expect((server.requests[1].headers["sec-fetch-mode"] == "navigate") == !sharedExecutor)

        // Android会跳过刷新造成的重复历史；刷新子页后仍应一步返回首页。
        web.reload()
        let reloadDeadline = ContinuousClock.now + .seconds(8)
        while (server.requests.filter { $0.path == "/child" }.count != 2 || web.isLoading || state.loading),
              ContinuousClock.now < reloadDeadline { await Task.yield() }
        try #require(server.requests.filter { $0.path == "/child" }.count == 2 && !state.loading && state.error == nil)
        webNavigation.goBack()
        let backDeadline = ContinuousClock.now + .seconds(8)
        while (web.url?.path != "/home" || web.isLoading || webNavigation.canGoBack), ContinuousClock.now < backDeadline {
            await Task.yield()
        }
        try #require(web.url?.path == "/home" && !web.isLoading && !webNavigation.canGoBack)
        #expect(try await web.evaluateJavaScript("document.getElementById('page').textContent") as? String == "Home")
        #expect(server.requests.filter { $0.path == "/child" }.count == 2)
        if sharedExecutor {
            #expect(server.requests.allSatisfy { $0.headers["x-history"] == "fixture" && $0.headers["sec-fetch-mode"] == nil })
            #expect(try await web.evaluateJavaScript("window.readHistoryFixture()") as? String == "", "返回后原页面桥必须绑定到恢复后的请求上下文")
        }
    }

    @Test("同文档pushState与hash返回恢复首页且不发起额外文档请求",
          arguments: [(false, "#child", true), (false, "hash", true), (true, "#child", true), (true, "hash", true),
                      (true, "#child", false), (true, "hash", false), (false, "/child", true), (true, "/child", true)])
    func webHistoryBackReturnsWithinDocument(injectedHTML: Bool, destination: String, withBaseURL: Bool) async throws {
        let html = """
        <!doctype html><html><body><p id="page">Home</p><script>
        function updatePage() { document.getElementById('page').textContent = location.hash === '#child' || location.pathname === '/child' ? 'Child' : 'Home'; }
        addEventListener('popstate', updatePage);
        addEventListener('hashchange', updatePage);
        </script></body></html>
        """
        let server = try VideoStillFixtureServer(directory: .temporaryDirectory, routes: [
            "/home": .init(body: Data(html.utf8), type: "text/html")
        ])
        let base = try await server.start()
        defer { server.stop() }
        var source = RSSSource(name: "Same-document history fixture", url: base.appendingPathComponent("home").absoluteString)
        source.importedFromLegado = true; source.singleUrl = true; source.enabledCookieJar = true
        source.header = "{}"; source.cacheFirst = false; source.loadWithBaseUrl = withBaseURL
        let target: RSSOpenTarget
        if injectedHTML { target = .html(html, baseURL: source.url) }
        else { target = try #require(try await RSSOpenTarget.resolve(source: source)) }
        let state = State()
        let webNavigation = RSSWebNavigationState()
        let window = try host(RSSSourcePageWebView(source: source, target: target,
            error: Binding(get: { state.error }, set: { state.error = $0 }),
            loading: Binding(get: { state.loading }, set: { state.loading = $0 }), webNavigation: webNavigation))
        defer { window.isHidden = true; window.rootViewController = nil }
        let firstDeadline = ContinuousClock.now + .seconds(8)
        while state.loading, ContinuousClock.now < firstDeadline { await Task.yield() }
        try #require(!state.loading && state.error == nil)
        let web = try #require(findWeb(window))
        #expect(!webNavigation.canGoBack)
        let initialURL = web.url
        _ = try await web.evaluateJavaScript(destination == "hash" ? "location.hash = 'child'; void 0" : "history.pushState({}, '', '\(destination)'); updatePage(); void 0")
        let childDeadline = ContinuousClock.now + .seconds(8)
        while !webNavigation.canGoBack, ContinuousClock.now < childDeadline { await Task.yield() }
        #expect(try await web.evaluateJavaScript("document.getElementById('page').textContent") as? String == "Child")
        #expect(web.canGoBack)
        #expect(web.backForwardList.backList.count == 1)
        try #require(webNavigation.canGoBack)
        webNavigation.goBack()
        let backDeadline = ContinuousClock.now + .seconds(8)
        while (web.url != initialURL || webNavigation.canGoBack || state.loading), ContinuousClock.now < backDeadline { await Task.yield() }
        #expect(state.error == nil)
        #expect(!webNavigation.canGoBack)
        #expect(web.url == initialURL)
        #expect(try await web.evaluateJavaScript("document.getElementById('page').textContent") as? String == "Home")
        #expect(server.requests.count == (injectedHTML ? 0 : 1))
    }

    @Test("返回不会自动重送共享执行器的POST表单")
    func historyDoesNotResubmitPost() async throws {
        let server = try VideoStillFixtureServer(directory: .temporaryDirectory, routes: [
            "/form": .init(body: Data("<a id='child' href='/child'>Open child</a>".utf8), allowedMethods: ["POST"]),
            "/child": .init(body: Data("<p id='page'>Child</p>".utf8))
        ])
        let base = try await server.start()
        defer { server.stop() }
        var source = RSSSource(name: "History POST fixture", url: base.appendingPathComponent("form").absoluteString)
        source.importedFromLegado = true; source.singleUrl = true; source.cacheFirst = false
        var request = URLRequest(url: base.appendingPathComponent("form"))
        request.httpMethod = "POST"; request.httpBody = Data("fixture=readonly".utf8)
        let state = State()
        let webNavigation = RSSWebNavigationState()
        let window = try host(RSSSourcePageWebView(source: source, target: .request(request),
            error: Binding(get: { state.error }, set: { state.error = $0 }),
            loading: Binding(get: { state.loading }, set: { state.loading = $0 }), webNavigation: webNavigation))
        defer { window.isHidden = true; window.rootViewController = nil }
        let firstDeadline = ContinuousClock.now + .seconds(8)
        while state.loading, ContinuousClock.now < firstDeadline { await Task.yield() }
        try #require(!state.loading && state.error == nil)
        let web = try #require(findWeb(window))
        _ = try await web.evaluateJavaScript("document.getElementById('child').click(); void 0")
        let deadline = ContinuousClock.now + .seconds(8)
        while (!webNavigation.canGoBack || state.loading), ContinuousClock.now < deadline { await Task.yield() }
        try #require(webNavigation.canGoBack && state.error == nil)
        webNavigation.goBack()
        #expect(state.error == RSSWebFailure.formBodyUnavailable.errorDescription)
        #expect(server.requests.filter { $0.path == "/form" }.count == 1)
        #expect(try await web.evaluateJavaScript("document.getElementById('page').textContent") as? String == "Child")
    }

    @Test("浏览器路径跨同源导航后仍响应源删除和登录撤销", arguments: [false, true])
    func browserRevocationSurvivesNavigation(deleteSource: Bool) async throws {
        let root = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = RSSStore(storageDirectory: root)
        let server = try VideoStillFixtureServer(directory: root, routes: [
            "/start": .init(body: Data("<p id='live'>Start</p><a id='next' href='/next'>Next</a>".utf8)),
            "/next": .init(body: Data("<p id='live'>Next</p><script>window.activeDocument=true</script>".utf8))
        ])
        let base = try await server.start()
        defer {
            server.stop()
            do { try FileManager.default.removeItem(at: root) } catch { Issue.record(error) }
        }
        var source = RSSSource(name: "Native revocation", url: base.appendingPathComponent("start").absoluteString)
        source.importedFromLegado = true; source.singleUrl = true; source.enabledCookieJar = true
        store.addSource(source)
        let state = State()
        let target = try #require(try await RSSOpenTarget.resolve(source: source, owner: store))
        let webNavigation = RSSWebNavigationState()
        let window = try host(RSSSourcePageWebView(source: source, target: target,
            error: Binding(get: { state.error }, set: { state.error = $0 }),
            loading: Binding(get: { state.loading }, set: { state.loading = $0 }), owner: store, webNavigation: webNavigation))
        defer { window.isHidden = true; window.rootViewController = nil }
        var deadline = ContinuousClock.now + .seconds(8)
        while state.loading, ContinuousClock.now < deadline { await Task.yield() }
        let web = try #require(findWeb(window))
        _ = try await web.evaluateJavaScript("document.getElementById('next').click(); void 0")
        deadline = ContinuousClock.now + .seconds(8)
        while (web.url?.path != "/next" || web.isLoading || state.loading), ContinuousClock.now < deadline { await Task.yield() }
        try #require(web.url?.path == "/next" && !state.loading)
        #expect(server.requests.map(\.path) == ["/start", "/next"])
        #expect(server.requests.allSatisfy { $0.headers["sec-fetch-mode"] == "navigate" })
        try #require(webNavigation.canGoBack)
        if deleteSource { store.removeSources(ids: [source.id]) }
        else { store.authenticationChanged(for: source.id) }
        deadline = ContinuousClock.now + .seconds(8)
        while state.error == nil, ContinuousClock.now < deadline { await Task.yield() }
        try #require(state.error != nil && !state.loading)
        while (try await web.evaluateJavaScript("typeof window.activeDocument") as? String) != "undefined",
              ContinuousClock.now < deadline { await Task.yield() }
        #expect(try await web.evaluateJavaScript("document.getElementById('live') === null") as? Bool == true)
        #expect(!web.configuration.defaultWebpagePreferences.allowsContentJavaScript)
        #expect(!webNavigation.canGoBack)
        webNavigation.goBack()
        #expect(server.requests.count == 2, "撤销后不能用旧返回操作重新发起请求")
        try await store.flushPersistence()
    }

    @Test("简单网页仍遵守enableJs，首文档不注入解析脚本桥")
    func nativePageRespectsScriptSetting() async throws {
        let server = try VideoStillFixtureServer(directory: .temporaryDirectory, routes: [
            "/page": .init(body: Data("<p id='visible'>Page</p><script>window.authorRan=true</script>".utf8))
        ])
        let base = try await server.start()
        defer { server.stop() }
        var source = RSSSource(name: "No scripts", url: base.appendingPathComponent("page").absoluteString)
        source.importedFromLegado = true; source.singleUrl = true; source.enabledCookieJar = true; source.enableJs = false
        let target = try #require(try await RSSOpenTarget.resolve(source: source))
        let state = State()
        let window = try host(RSSSourcePageWebView(source: source, target: target,
            error: Binding(get: { state.error }, set: { state.error = $0 }),
            loading: Binding(get: { state.loading }, set: { state.loading = $0 })))
        defer { window.isHidden = true; window.rootViewController = nil }
        let deadline = ContinuousClock.now + .seconds(8)
        while state.loading, ContinuousClock.now < deadline { await Task.yield() }
        let web = try #require(findWeb(window))
        #expect(!state.loading && state.error == nil)
        #expect(server.requests.count == 1 && server.requests.first?.headers["sec-fetch-mode"] == "navigate")
        #expect(try await web.evaluateJavaScript("typeof window.authorRan === 'undefined' && typeof java === 'undefined'") as? Bool == true)
        #expect(try await web.evaluateJavaScript("document.getElementById('visible').textContent") as? String == "Page")
    }

    @Test("CookieJar打开仍不能把私有头交给原生浏览器重定向")
    func privateHeadersRetainScopedExecutor() async throws {
        let destination = try VideoStillFixtureServer(directory: .temporaryDirectory, routes: [
            "/final": .init(body: Data("<p id='final'>Final</p>".utf8))
        ])
        let finalURL = try await destination.start().appendingPathComponent("final")
        let origin = try VideoStillFixtureServer(directory: .temporaryDirectory, routes: [
            "/start": .init(body: Data(), status: "302 Found", headers: ["Location": finalURL.absoluteString],
                            requiredHeaders: ["authorization": "Bearer fixture", "x-private": "fixture"])
        ])
        let base = try await origin.start()
        defer { origin.stop(); destination.stop() }
        var source = RSSSource(name: "Private redirect", url: base.appendingPathComponent("start").absoluteString)
        source.importedFromLegado = true; source.singleUrl = true; source.enabledCookieJar = true
        source.header = #"{"Authorization":"Bearer fixture","X-Private":"fixture"}"#
        let state = State()
        let target = try #require(try await RSSOpenTarget.resolve(source: source))
        let window = try host(RSSSourcePageWebView(source: source, target: target,
            error: Binding(get: { state.error }, set: { state.error = $0 }),
            loading: Binding(get: { state.loading }, set: { state.loading = $0 })))
        defer { window.isHidden = true; window.rootViewController = nil }
        let deadline = ContinuousClock.now + .seconds(8)
        while state.loading, ContinuousClock.now < deadline { await Task.yield() }
        try #require(!state.loading && state.error == nil)
        let first = try #require(origin.requests.first), last = try #require(destination.requests.first)
        #expect(first.headers["authorization"] == "Bearer fixture" && first.headers["x-private"] == "fixture")
        #expect(first.headers["sec-fetch-mode"] == nil)
        #expect(last.headers["authorization"] == nil && last.headers["x-private"] == nil)
        #expect(origin.requests.count == 1 && destination.requests.count == 1)
        let web = try #require(findWeb(window))
        #expect(try await web.evaluateJavaScript("document.getElementById('final').textContent") as? String == "Final")
    }

    private func host(_ view: some View) throws -> UIWindow {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: view)
        window.isHidden = false
        return window
    }
    private func findWeb(_ view: UIView) -> WKWebView? {
        (view as? WKWebView) ?? view.subviews.lazy.compactMap(findWeb).first
    }
}
