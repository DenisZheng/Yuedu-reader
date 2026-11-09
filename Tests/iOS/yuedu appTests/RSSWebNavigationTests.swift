import SwiftUI
import Testing
import UIKit
import WebKit
@testable import yuedu_app

@Suite("RSS web navigation and actions", .serialized)
@MainActor
struct RSSWebNavigationTests {
    @MainActor @Observable
    final class LoadState {
        var loading = true
        var error: String?
        var actions: [RSSWebAction] = []
    }

    @Test("导航拦截绑定url，true只拦截一次，不发送HTTP也不离开当前文档")
    func overrideCancelsOnce() async throws {
        try await withPage { source in
            source.shouldOverrideUrlLoading = "source.put('intercepts',String(Number(source.get('intercepts')||'0')+1));url.indexOf('/blocked')>=0"
        } run: { web, _, store, source, server in
            _ = try await web.evaluateJavaScript("document.getElementById('blocked').click()")
            let deadline = ContinuousClock.now + .seconds(6)
            while store.variables(for: source.id)["intercepts"] == nil, ContinuousClock.now < deadline { await Task.yield() }
            #expect(store.variables(for: source.id)["intercepts"] == "1")
            #expect(server.requests.filter { $0.path == "/blocked" }.isEmpty)
            #expect(try await web.evaluateJavaScript("document.getElementById('blocked') !== null") as? Bool == true)
        }
    }

    @Test("未拦截导航复用源请求和登录检查，只请求一次并在新页面执行完成注入")
    func navigationUsesSharedRequestPipeline() async throws {
        try await withPage { source in
            source.header = #"{"X-Navigation":"fixture"}"#
            source.loginCheckJs = "source.put('checked',String(result.code()));result"
            source.shouldOverrideUrlLoading = "source.put('intercepts',String(Number(source.get('intercepts')||'0')+1));false"
        } run: { web, _, store, source, server in
            _ = try await web.evaluateJavaScript("document.getElementById('allowed').click()")
            let deadline = ContinuousClock.now + .seconds(6)
            while (try await web.evaluateJavaScript("document.getElementById('next') !== null && window.finished === true") as? Bool) != true,
                  ContinuousClock.now < deadline { await Task.yield() }
            #expect(store.variables(for: source.id)["intercepts"] == "1")
            #expect(store.variables(for: source.id)["checked"] == "200")
            let requests = server.requests.filter { $0.path == "/allowed" }
            #expect(requests.count == 1)
            #expect(requests.first?.headers["x-navigation"] == "fixture")
        }
    }

    @Test("拦截脚本动作成功后只交付一次，抛错后不能交付半截动作")
    func interceptionActionsAreTransactional() async throws {
        for shouldThrow in [false, true] {
            try await withPage { source in
                source.shouldOverrideUrlLoading = "java.open('sort','/category','Category');" + (shouldThrow ? "throw new Error('private fixture')" : "true")
            } run: { web, state, _, _, server in
                _ = try await web.evaluateJavaScript("document.getElementById('blocked').click()")
                let deadline = ContinuousClock.now + .seconds(6)
                while state.actions.isEmpty && state.error == nil, ContinuousClock.now < deadline { await Task.yield() }
                #expect(server.requests.isEmpty)
                if shouldThrow { #expect(state.actions.isEmpty && state.error != nil) }
                else { #expect(state.actions == [.sort(url: "/category", title: "Category", origin: nil)]) }
            }
        }
    }

    @Test("预注入页面桥同步读写仅当前源状态；iframe即使获得协议名也不能调用")
    func pageBridgeChecksFrame() async throws {
        try await withPage { source in
            source.preloadJs = "source.put('pageValue','fixture');window.saved=source.get('pageValue');"
        } run: { web, state, store, source, server in
            _ = try await web.evaluateJavaScript("window.saved")
            #expect(store.variables(for: source.id)["pageValue"] == "fixture")
            _ = try await web.evaluateJavaScript("java.open('sort','/category','Category')")
            let deadline = ContinuousClock.now + .seconds(6)
            while state.actions.isEmpty, ContinuousClock.now < deadline { await Task.yield() }
            #expect(state.actions == [.sort(url: "/category", title: "Category", origin: nil)])
            let protocolName = try #require(try await web.evaluateJavaScript("window.__rssBridgePromptName") as? String)
            let invoke = "window.answer=prompt(" + String(decoding: try JSONSerialization.data(withJSONObject: protocolName, options: [.fragmentsAllowed]), as: UTF8.self) + ",JSON.stringify({method:'source.put',args:['iframe','bad']}));"
            let script = "<body><script>" + invoke + "parent.postMessage('finished','*')</script></body>"
            let literal = String(decoding: try JSONSerialization.data(withJSONObject: script, options: [.fragmentsAllowed]), as: UTF8.self)
            _ = try await web.evaluateJavaScript("window.frameDone=false;window.addEventListener('message',()=>window.frameDone=true,{once:true});let f=document.createElement('iframe');document.body.appendChild(f);f.contentDocument.open();f.contentDocument.write(\(literal));f.contentDocument.close();")
            while (try await web.evaluateJavaScript("window.frameDone") as? Bool) != true, ContinuousClock.now < deadline { await Task.yield() }
            #expect(try await web.evaluateJavaScript("window.frameDone") as? Bool == true)
            #expect(store.variables(for: source.id)["iframe"] == nil)
            #expect(server.requests.isEmpty)
        }
    }

    @Test("CookieJar关闭时显式Cookie与domain/path匹配Cookie仍送到真实图片；网页注销同步回原生")
    func webCookieLifecycle() async throws {
        let key = "rss_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        defer {
            for cookie in HTTPCookieStorage.shared.cookies ?? [] where cookie.name.hasPrefix(key) { HTTPCookieStorage.shared.deleteCookie(cookie) }
        }
        try await withPage(configure: { source in
            let url = URL(string: source.url)!
            let cookie = HTTPCookie(properties: [.domain: url.host!, .path: "/protected", .name: key, .value: "native", HTTPCookiePropertyKey("HttpOnly"): "TRUE"])!
            HTTPCookieStorage.shared.setCookie(cookie)
            source.enabledCookieJar = false
            source.header = "{\"Cookie\":\"\(key)_explicit=manual\"}"
        }, pageHTML: "<img id='protected' src='protected/image'><img id='public' src='public/image'><a id='allowed' href='allowed'>Next</a>") { web, _, _, source, server in
            let protected = try #require(requests("/protected/image", from: server).first)
            let publicImage = try #require(requests("/public/image", from: server).first)
            #expect(protected.headers["cookie"]?.contains(key + "=native") == true)
            #expect(protected.headers["cookie"]?.contains(key + "_explicit=manual") == true)
            #expect(publicImage.headers["cookie"]?.contains(key + "=native") != true)
            #expect(try await web.evaluateJavaScript("document.getElementById('protected').naturalWidth") as? Int == 1)
            _ = try await web.evaluateJavaScript("document.cookie='\(key)_web=created; Path=/allowed'")
            let url = URL(string: source.url)!.appendingPathComponent("allowed")
            var deadline = ContinuousClock.now + .seconds(6)
            while CookieStore.shared.requestHeader(for: url).contains(key + "_web=created") == false, ContinuousClock.now < deadline { await Task.yield() }
            #expect(CookieStore.shared.requestHeader(for: url).contains(key + "_web=created"))
            _ = try await web.evaluateJavaScript("document.cookie='\(key)_web=; Max-Age=0; Path=/allowed';document.getElementById('allowed').click()")
            deadline = ContinuousClock.now + .seconds(6)
            while requests("/allowed", from: server).isEmpty, ContinuousClock.now < deadline { await Task.yield() }
            let navigation = requests("/allowed", from: server).last
            #expect(navigation?.headers["cookie"]?.contains(key + "_web=") != true)
        }
    }

    private func withPage(configure: (inout RSSSource) -> Void, pageHTML: String = "<a id='blocked' href='blocked'>Blocked</a><a id='allowed' href='allowed'>Allowed</a>",
                          run: (WKWebView, LoadState, RSSStore, RSSSource, VideoStillFixtureServer) async throws -> Void) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = RSSStore(storageDirectory: directory)
        let server = try VideoStillFixtureServer(directory: directory, routes: [
            "/allowed": .init(body: Data("<p id='next'>Next</p>".utf8), type: "text/html"),
            "/blocked": .init(body: Data("<p>Unexpected navigation</p>".utf8), type: "text/html"),
            "/protected/image": .init(body: Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")!, type: "image/png"),
            "/public/image": .init(body: Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")!, type: "image/png")
        ])
        let base = try await server.start()
        defer {
            server.stop()
            do { try FileManager.default.removeItem(at: directory) } catch { Issue.record(error) }
        }
        var source = RSSSource(name: "Navigation", url: base.absoluteString)
        source.importedFromLegado = true
        source.injectJs = "window.finished=true"
        configure(&source)
        store.addSource(source)
        let state = LoadState()
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: RSSSourcePageWebView(source: source,
            target: .articleHTML(pageHTML, baseURL: base.absoluteString),
            error: Binding(get: { state.error }, set: { state.error = $0 }),
            loading: Binding(get: { state.loading }, set: { state.loading = $0 }), owner: store,
            onAction: { state.actions.append($0.action) }))
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        do {
            let deadline = ContinuousClock.now + .seconds(8)
            while state.loading, ContinuousClock.now < deadline { await Task.yield() }
            try #require(!state.loading && state.error == nil)
            let web = try #require(findWeb(in: window))
            try await run(web, state, store, source, server)
        } catch { try await store.flushPersistence(); throw error }
        try await store.flushPersistence()
    }
    private func requests(_ path: String, from server: VideoStillFixtureServer) -> [VideoStillFixtureServer.Request] {
        var result: [VideoStillFixtureServer.Request] = []
        for request in server.requests where request.path == path { result.append(request) }
        return result
    }
    private func findWeb(in view: UIView) -> WKWebView? {
        (view as? WKWebView) ?? view.subviews.lazy.compactMap { findWeb(in: $0) }.first
    }
}
