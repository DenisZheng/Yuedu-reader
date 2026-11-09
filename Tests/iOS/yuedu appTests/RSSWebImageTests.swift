import SwiftUI
import WebKit
import Testing
@testable import yuedu_app

@Suite("RSS production WebKit images", .serialized)
@MainActor struct RSSWebImageTests {
    @MainActor @Observable final class Load {
        var loading = true
        var error: String?
    }
    @Test("真实规则网页私有头及coverDecode字节到达WebKit图片；不依赖页面JS")
    func staticImage() async throws {
        try await withPage(js: false, html: "<p id='article'>Article</p><img id='photo' src='/protected'>") { web, state, server in
            let width = try await web.evaluateJavaScript("document.getElementById('photo').naturalWidth") as? Int
            #expect(width == 4)
            #expect(state.error == nil)
            #expect(server.requests.count == 1)
            #expect(server.requests.first?.headers["x-fixture"] == "private-image-fixture")
        }
    }
    @Test("懒加载src及动态innerHTML/srcset都使用同一资源管道；逻辑URL不变")
    func dynamicImages() async throws {
        try await withPage(js: true, html: "<div id='host'></div>", inject: """
            let image=new Image();image.id='lazy';image.src='/protected';document.body.appendChild(image);
            document.getElementById('host').innerHTML='<img id="set" srcset="/protected?one 1x, /protected?two 2x" src="/protected">';
            """) { web, state, server in
            let deadline = ContinuousClock.now + .seconds(5)
            var widths: [Int] = []
            repeat {
                widths = try await web.evaluateJavaScript("['lazy','set'].map(id=>document.getElementById(id)?.naturalWidth||0)") as? [Int] ?? []
                if widths == [4,2] { break }
                await Task.yield()
            } while ContinuousClock.now < deadline
            // naturalWidth按srcset密度修正：4px的2x候选报告2，而不是原始4px。
            #expect(widths == [4,2])
            #expect(state.error == nil)
            let src = try await web.evaluateJavaScript("document.getElementById('lazy').src") as? String
            #expect(src?.hasPrefix("http://127.0.0.1:") == true)
            #expect(src?.contains("reader-rss-image") == false)
            #expect(server.requests.count >= 2)
            #expect(server.requests.allSatisfy { $0.headers["x-fixture"] == "private-image-fixture" })
        }
    }
    @Test("原生图片响应HttpOnly Cookie传播到WebKit后续真实请求，不暴露给网页JS")
    func nativeResponseCookieToWebKit() async throws {
        let name = "rssimage" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        try await withPage(js: true, html: "<img id='photo' src='/protected'>", cookie: name) { web, state, server in
            let cookie = try await web.evaluateJavaScript("document.cookie") as? String ?? ""
            #expect(!cookie.contains(name + "="))
            _ = try await web.evaluateJavaScript("fetch('/probe');void 0")
            let deadline = ContinuousClock.now + .seconds(5)
            while !server.requests.contains(where: { $0.path == "/probe" }), ContinuousClock.now < deadline { await Task.yield() }
            #expect(server.requests.last { $0.path == "/probe" }?.headers["cookie"]?.contains(name + "=synthetic") == true)
            #expect(state.error == nil)
        }
    }
    @Test("黑名单优先：主HTML保留，已代理图片也在网络前阻断")
    func filteredImage() async throws {
        try await withPage(js: true, html: "<p id='article'>Article</p><img id='photo' src='/protected'>", blocked: true) { web, state, server in
            let text = try await web.evaluateJavaScript("document.getElementById('article').textContent") as? String
            let width = try await web.evaluateJavaScript("document.getElementById('photo').naturalWidth") as? Int
            #expect(text == "Article")
            #expect(width == 0)
            #expect(state.error == nil)
            #expect(server.requests.isEmpty)
        }
    }
    private func withPage(js: Bool, html: String, inject: String? = nil, blocked: Bool = false, cookie: String? = nil,
        run: (WKWebView, Load, VideoStillFixtureServer) async throws -> Void) async throws {
        let directory = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = RSSStore(storageDirectory: directory)
        let plain = try #require(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAQAAAAECAYAAACp8Z5+AAAAEklEQVR4nGP438DwHxkzkC4AAFBPJ+HrAPilAAAAAElFTkSuQmCC"))
        let server = try VideoStillFixtureServer(directory: directory, routes: [
            "/protected": .init(body: Data(plain.map { $0 ^ 0x5a }), type: "application/octet-stream",
                                headers: cookie.map { ["Set-Cookie": "\($0)=synthetic; Path=/; HttpOnly"] } ?? [:], requiredHeaders: ["x-fixture": "private-image-fixture"]),
            "/probe": .init(body: Data("OK".utf8))
        ])
        let base = try await server.start()
        defer {
            server.stop()
            if let cookie { CookieStore.shared.remove(url: base.absoluteString, key: cookie) }
            do { try FileManager.default.removeItem(at: directory) } catch { Issue.record(error) }
        }
        var source = RSSSource(name: "Native Web images", url: base.absoluteString)
        source.importedFromLegado = true
        source.enableJs = js
        source.header = #"{"X-Fixture":"private-image-fixture"}"#
        source.jsLib = "function fixtureKey(){return 0x5a}"
        source.coverDecodeJs = "@js:var b=result.readAllBytes();for(var i=0;i<b.length;i++)b[i]^=fixtureKey();b"
        source.injectJs = inject
        if blocked { source.contentBlacklist = base.absoluteString }
        store.addSource(source)
        let state = Load()
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: RSSSourcePageWebView(source: source,
            target: .articleHTML(html, baseURL: base.absoluteString),
            error: Binding(get: { state.error }, set: { state.error = $0 }),
            loading: Binding(get: { state.loading }, set: { state.loading = $0 }), owner: store))
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        do {
            let deadline = ContinuousClock.now + .seconds(8)
            while state.loading, ContinuousClock.now < deadline { await Task.yield() }
            try #require(!state.loading && state.error == nil)
            let web = try #require(findWeb(window))
            try await run(web, state, server)
        } catch { try await store.flushPersistence(); throw error }
        try await store.flushPersistence()
    }
    private func findWeb(_ root: UIView) -> WKWebView? {
        (root as? WKWebView) ?? root.subviews.lazy.compactMap(findWeb).first
    }
}
