import SwiftUI
import WebKit
import Testing
@testable import yuedu_app

@Suite("RSS native web destinations", .serialized)
@MainActor struct RSSNativeWebFlowTests {
    @MainActor @Observable final class Loading { var error: String?; var loading = true }
    private let pixel = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAQAAAAECAYAAACp8Z5+AAAAEklEQVR4nGP438DwHxkzkC4AAFBPJ+HrAPilAAAAAElFTkSuQmCC")!

    @Test("网页照片动作真正推入原生查看器，认证/解码可见，撤销后旧图片消失")
    func photoActionReachesNativeImage() async throws {
        try await withRoot { owner, source, server, base, window in
            let web = try await readyWeb(window)
            _ = try await web.evaluateJavaScript("java.showPhoto('/image')")
            let deadline = ContinuousClock.now + .seconds(8)
            while !hasFixtureImage(window), ContinuousClock.now < deadline { await Task.yield() }
            #expect(hasFixtureImage(window))
            #expect(server.requests.filter { $0.path == "/image" }.count == 1)
            #expect(server.requests.last { $0.path == "/image" }?.headers["x-fixture"] == "native-destination")
            owner.authenticationChanged(for: source.id)
            let cleared = ContinuousClock.now + .seconds(5)
            while hasFixtureImage(window), ContinuousClock.now < cleared { await Task.yield() }
            #expect(!hasFixtureImage(window))
        }
    }
    @Test("网页JSON分类动作真正进入RSSFeedView并解析/持久化该分类，不重开启动页")
    func categoryActionReachesFeed() async throws {
        try await withRoot { owner, source, server, base, window in
            let web = try await readyWeb(window)
            _ = try await web.evaluateJavaScript("java.open('sort',JSON.stringify({'Native category':'/list'}),null,null)")
            let deadline = ContinuousClock.now + .seconds(8)
            let entry = RSSSortEntry(name: "Native category", url: base.appendingPathComponent("list").absoluteString)
            while owner.articles(for: source.id, scope: .category(entry)).isEmpty, ContinuousClock.now < deadline { await Task.yield() }
            let rows = owner.articles(for: source.id, scope: .category(entry))
            #expect(rows.map(\.title) == ["Native feed item"])
            #expect(server.requests.filter { $0.path == "/list" }.count == 1)
        }
    }
    @Test("登录模式实际执行网站JS/POST/HttpOnly Cookie，但不执行RSS注入或登录检查")
    func loginPageOwnsItsForm() async throws {
        let directory = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let owner = RSSStore(storageDirectory: directory)
        let name = "rsslogin" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let server = try VideoStillFixtureServer(directory: directory, routes: [
            "/login": .init(body: Data("<form id='form' method='post' action='/session'><input name='user' value='synthetic'></form><script>window.websiteRuns=true</script>".utf8), type: "text/html", requiredHeaders: ["x-fixture": "login-start"]),
            "/session": .init(body: Data("<p id='success'>Signed in synthetic</p>".utf8), type: "text/html", headers: ["Set-Cookie": "\(name)=synthetic; Path=/private; HttpOnly"], allowedMethods: ["POST"])
        ])
        let base = try await server.start()
        defer {
            server.stop(); CookieStore.shared.remove(url: base.absoluteString, key: name)
            do { try FileManager.default.removeItem(at: directory) } catch { Issue.record(error) }
        }
        var source = RSSSource(name: "Login native", url: base.absoluteString)
        source.enableJs = false; source.header = #"{"X-Fixture":"login-start"}"#
        source.loginCheckJs = "throw new Error('do not execute in login website')"
        source.preloadJs = "throw new Error('do not preload in login website')"
        source.injectJs = "throw new Error('do not inject in login website')"
        owner.addSource(source)
        let target = try await RSSOpenTarget.rulePage(base.appendingPathComponent("login").absoluteString, source: source, owner: owner)
        let state = Loading(), bridge = RSSWebAuthenticationBridge()
        let window = try window(root: RSSSourcePageWebView(source: source, target: target,
            error: Binding(get: { state.error }, set: { state.error = $0 }), loading: Binding(get: { state.loading }, set: { state.loading = $0 }),
            owner: owner, authentication: true, authenticationBridge: bridge))
        defer { window.isHidden = true; window.rootViewController = nil }
        do {
            let web = try await readyWeb(window)
            let deadline = ContinuousClock.now + .seconds(6)
            while state.loading, ContinuousClock.now < deadline { await Task.yield() }
            #expect(state.error == nil)
            let ran = try await web.evaluateJavaScript("window.websiteRuns===true && typeof java==='undefined'") as? Bool
            #expect(ran == true)
            _ = try await web.evaluateJavaScript("document.getElementById('form').submit();void 0")
            let posted = ContinuousClock.now + .seconds(6)
            while !server.requests.contains(where: { $0.method == "POST" }), ContinuousClock.now < posted { await Task.yield() }
            let request = try #require(server.requests.last { $0.method == "POST" })
            #expect(String(decoding: request.body, as: UTF8.self) == "user=synthetic")
            #expect(request.headers["x-fixture"] == nil)
            var html = ""
            let finished = ContinuousClock.now + .seconds(6)
            while !html.contains("Signed in synthetic"), ContinuousClock.now < finished {
                if let finish = bridge.finish {
                    // POST后的文档切换窗口内明确为未就绪；其他错误仍使测试失败。
                    do { html = try await finish() }
                    catch RSSWebFailure.resourceUnavailable { html = "" }
                }
                await Task.yield()
            }
            #expect(html.contains("Signed in synthetic"))
            #expect(CookieStore.shared.requestHeader(for: base.appendingPathComponent("private/data")).contains(name + "=synthetic"))
            #expect(!CookieStore.shared.requestHeader(for: base.appendingPathComponent("public")).contains(name + "="))
        } catch { try await owner.flushPersistence(); throw error }
        try await owner.flushPersistence()
    }
    @Test("showWebLog只在源开启时安装console记录；关闭源不暴露日志处理器")
    func webLogFollowsSource() async throws {
        for enabled in [true, false] {
            let directory = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            let owner = RSSStore(storageDirectory: directory)
            var source = RSSSource(name: "Web log", url: "https://weblog-" + UUID().uuidString + ".invalid")
            source.showWebLog = enabled
            owner.addSource(source)
            let window = try window(root: NavigationStack {
                RSSSourcePageScreen(source: source, target: .articleHTML("<p>log</p><script>console.log('fixture')</script>", baseURL: "about:blank"), owner: owner)
            })
            let web = try await readyWeb(window)
            let installed = try await web.evaluateJavaScript("window.__readerRSSConsoleInstalled===true && !!(window.webkit&&window.webkit.messageHandlers&&window.webkit.messageHandlers.readerRSSConsole)") as? Bool
            #expect(installed == enabled)
            window.isHidden = true; window.rootViewController = nil
            try await owner.flushPersistence()
            do { try FileManager.default.removeItem(at: directory) } catch { Issue.record(error) }
        }
    }
    private func withRoot(_ run: (RSSStore, RSSSource, VideoStillFixtureServer, URL, UIWindow) async throws -> Void) async throws {
        let directory = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let owner = RSSStore(storageDirectory: directory)
        let server = try VideoStillFixtureServer(directory: directory, routes: [
            "/image": .init(body: Data(pixel.map { $0 ^ 0x5a }), type: "application/octet-stream", requiredHeaders: ["x-fixture": "native-destination"]),
            "/list": .init(body: Data("<div class='item'><a href='/article'>Native feed item</a></div>".utf8), type: "text/html", requiredHeaders: ["x-fixture": "native-destination"])
        ])
        let base = try await server.start()
        defer {
            server.stop()
            do { try FileManager.default.removeItem(at: directory) } catch { Issue.record(error) }
        }
        var source = RSSSource(name: "Native flow", url: base.absoluteString)
        source.importedFromLegado = true; source.preloadJs = "window.nativeReady=true"
        source.header = #"{"X-Fixture":"native-destination"}"#
        source.coverDecodeJs = "@js:var b=result.readAllBytes();for(var i=0;i<b.length;i++)b[i]^=0x5a;b"
        source.ruleArticles = "class.item"; source.ruleTitle = "tag.a@text"; source.ruleLink = "tag.a@href"
        owner.addSource(source)
        let window = try window(root: NavigationStack {
            RSSSourcePageScreen(source: source, target: .articleHTML("<p>Native source</p>", baseURL: base.absoluteString), owner: owner)
        })
        defer { window.isHidden = true; window.rootViewController = nil }
        do { try await run(owner, source, server, base, window) }
        catch { try await owner.flushPersistence(); throw error }
        try await owner.flushPersistence()
    }
    private func window<V: View>(root: V) throws -> UIWindow {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: root)
        window.makeKeyAndVisible()
        return window
    }
    private func readyWeb(_ root: UIView) async throws -> WKWebView {
        let deadline = ContinuousClock.now + .seconds(8)
        while ContinuousClock.now < deadline {
            if let web = findWeb(root), web.url != nil, !web.isLoading,
               try await web.evaluateJavaScript("document.readyState==='complete'") as? Bool == true { return web }
            await Task.yield()
        }
        throw RSSWebFailure.resourceUnavailable
    }
    private func findWeb(_ root: UIView) -> WKWebView? { (root as? WKWebView) ?? root.subviews.lazy.compactMap(findWeb).first }
    private func hasFixtureImage(_ root: UIView) -> Bool {
        if let image = (root as? UIImageView)?.image, image.cgImage?.width == 4 { return true }
        return root.subviews.contains(where: hasFixtureImage)
    }
}
