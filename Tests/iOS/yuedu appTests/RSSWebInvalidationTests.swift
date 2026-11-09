import SwiftUI
import Testing
import UIKit
import WebKit
@testable import yuedu_app

@Suite("RSS live web invalidation", .serialized)
@MainActor
struct RSSWebInvalidationTests {
    @MainActor @Observable
    final class OwnerState {
        var owner: RSSStore
        let source: RSSSource
        init(owner: RSSStore, source: RSSSource) { self.owner = owner; self.source = source }
    }
    private struct MutableOwnerPage: View {
        let state: OwnerState
        @Binding var error: String?
        @Binding var loading: Bool
        var body: some View {
            RSSSourcePageWebView(source: state.source, target: .articleHTML("<p>Owner</p>", baseURL: state.source.url),
                                 error: $error, loading: $loading, owner: state.owner)
        }
    }
    @Test("已打开的网页在登录、配置、外部变量或删除后撤销，旧JS文档不能继续运行")
    func openedDocumentIsRevoked() async throws {
        for change in 0..<5 {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            let store = RSSStore(storageDirectory: directory)
            defer { do { try FileManager.default.removeItem(at: directory) } catch { Issue.record(error) } }
            var source = RSSSource(name: "Revocation", url: "https://revocation-\(UUID().uuidString.lowercased()).invalid/")
            source.ruleArticles = "class.item"
            source.injectJs = "window.liveDocument=true"
            store.addSource(source)
            let authenticationKey = RSSRuntime.authenticationKey(for: source)
            defer { LoginManager.shared.removeLoginHeader(sourceUrl: authenticationKey) }
            var loading = true
            var error: String?
            let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
            let window = UIWindow(windowScene: scene)
            window.rootViewController = UIHostingController(rootView: RSSSourcePageWebView(source: source,
                target: .articleHTML("<p id='live'>Allowed</p><script>window.pageState='private fixture'</script>", baseURL: source.url),
                error: Binding(get: { error }, set: { error = $0 }), loading: Binding(get: { loading }, set: { loading = $0 }), owner: store))
            window.makeKeyAndVisible()
            defer { window.isHidden = true; window.rootViewController = nil }
            var deadline = ContinuousClock.now + .seconds(6)
            while loading, ContinuousClock.now < deadline { await Task.yield() }
            #expect(!loading && error == nil)
            let web = try #require(findWeb(in: window))
            #expect(try await web.evaluateJavaScript("window.liveDocument === true") as? Bool == true)
            switch change {
            case 0: store.authenticationChanged(for: source.id)
            case 1: source.header = #"{"X-Revision":"new"}"#; store.updateSource(source)
            case 2: store.setVariables(["configured": "new"], for: source.id)
            case 3: store.removeSources(ids: [source.id])
            default: LoginManager.shared.storeLoginHeader(sourceUrl: authenticationKey, raw: #"{"X-Login":"new-fixture"}"#)
            }
            deadline = ContinuousClock.now + .seconds(6)
            while error == nil, ContinuousClock.now < deadline { await Task.yield() }
            #expect(error != nil && !loading)
            while (try await web.evaluateJavaScript("typeof window.pageState") as? String) != "undefined",
                  ContinuousClock.now < deadline { await Task.yield() }
            #expect(try await web.evaluateJavaScript("document.getElementById('live') === null") as? Bool == true)
            #expect(try await web.evaluateJavaScript("typeof window.liveDocument") as? String == "undefined")
            try await store.flushPersistence()
        }
    }

    @Test("网页自身导航后仍保留登录撤销，不能因navigation generation变化失去生命周期登记")
    func revocationSurvivesNavigation() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = RSSStore(storageDirectory: directory)
        let server = try VideoStillFixtureServer(directory: directory, routes: [
            "/next": .init(body: Data("<p id='next'>Next</p>".utf8), type: "text/html")
        ])
        let base = try await server.start()
        defer {
            server.stop()
            do { try FileManager.default.removeItem(at: directory) } catch { Issue.record(error) }
        }
        var source = RSSSource(name: "Navigation", url: base.absoluteString)
        source.injectJs = "window.finished=true"
        store.addSource(source)
        var loading = true
        var error: String?
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: RSSSourcePageWebView(source: source,
            target: .articleHTML("<a id='link' href='next'>Next</a>", baseURL: base.absoluteString),
            error: Binding(get: { error }, set: { error = $0 }), loading: Binding(get: { loading }, set: { loading = $0 }), owner: store))
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        var deadline = ContinuousClock.now + .seconds(6)
        while loading, ContinuousClock.now < deadline { await Task.yield() }
        let web = try #require(findWeb(in: window))
        _ = try await web.evaluateJavaScript("document.getElementById('link').click()")
        deadline = ContinuousClock.now + .seconds(6)
        while (try await web.evaluateJavaScript("document.getElementById('next') !== null && window.finished === true") as? Bool) != true,
              ContinuousClock.now < deadline { await Task.yield() }
        #expect(web.url == base.appendingPathComponent("next"))
        #expect(server.requests.filter { $0.path == "/next" }.count == 1)
        store.authenticationChanged(for: source.id)
        deadline = ContinuousClock.now + .seconds(6)
        while error == nil, ContinuousClock.now < deadline { await Task.yield() }
        #expect(error != nil && !loading)
        while (try await web.evaluateJavaScript("typeof window.finished") as? String) != "undefined",
              ContinuousClock.now < deadline { await Task.yield() }
        #expect(try await web.evaluateJavaScript("document.getElementById('next') === null") as? Bool == true)
        try await store.flushPersistence()
    }

    @Test("即使URL和内容相同，切换持久owner也建立新文档及撤销登记")
    func ownerIdentityIsPartOfDocumentLifetime() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let first = RSSStore(storageDirectory: directory.appendingPathComponent("first"))
        let second = RSSStore(storageDirectory: directory.appendingPathComponent("second"))
        defer { do { try FileManager.default.removeItem(at: directory) } catch { Issue.record(error) } }
        let source = RSSSource(name: "Owner", url: "https://owner-\(UUID().uuidString.lowercased()).invalid/")
        first.addSource(source); second.addSource(source)
        let state = OwnerState(owner: first, source: source)
        var loading = true
        var error: String?
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: MutableOwnerPage(state: state,
            error: Binding(get: { error }, set: { error = $0 }), loading: Binding(get: { loading }, set: { loading = $0 })))
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        var deadline = ContinuousClock.now + .seconds(6)
        while loading, ContinuousClock.now < deadline { await Task.yield() }
        let web = try #require(findWeb(in: window))
        _ = try await web.evaluateJavaScript("window.oldOwnerMarker=true")
        state.owner = second
        deadline = ContinuousClock.now + .seconds(6)
        while (try await web.evaluateJavaScript("typeof window.oldOwnerMarker") as? String) != "undefined",
              ContinuousClock.now < deadline { await Task.yield() }
        #expect(try await web.evaluateJavaScript("typeof window.oldOwnerMarker") as? String == "undefined")
        #expect(error == nil)
        second.setVariables(["changed": "second"], for: source.id)
        deadline = ContinuousClock.now + .seconds(6)
        while error == nil, ContinuousClock.now < deadline { await Task.yield() }
        #expect(error != nil)
        try await first.flushPersistence(); try await second.flushPersistence()
    }

    @Test("生产拆除路径销毁旧JS文档，而不只是取消仍在加载的导航")
    func dismantleDisposesDocumentRealm() async throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        var loading = true
        var error: String?
        let source = RSSSource(name: "Teardown", url: "https://teardown.invalid/")
        window.rootViewController = UIHostingController(rootView: RSSSourcePageWebView(source: source,
            target: .html("<p id='old'>Old</p><script>window.oldRealm=true</script>", baseURL: source.url),
            error: Binding(get: { error }, set: { error = $0 }), loading: Binding(get: { loading }, set: { loading = $0 })))
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        var deadline = ContinuousClock.now + .seconds(6)
        while loading, ContinuousClock.now < deadline { await Task.yield() }
        let web = try #require(findWeb(in: window))
        #expect(try await web.evaluateJavaScript("window.oldRealm") as? Bool == true)
        let coordinator = try #require(web.navigationDelegate as? RSSSourcePageWebView.Coordinator)
        RSSSourcePageWebView.dismantleUIView(web, coordinator: coordinator)
        deadline = ContinuousClock.now + .seconds(6)
        while (try await web.evaluateJavaScript("typeof window.oldRealm") as? String) != "undefined",
              ContinuousClock.now < deadline { await Task.yield() }
        #expect(try await web.evaluateJavaScript("document.getElementById('old') === null") as? Bool == true)
        #expect(try await web.evaluateJavaScript("typeof window.oldRealm") as? String == "undefined")
        #expect(web.navigationDelegate == nil && web.configuration.userContentController.userScripts.isEmpty)
    }

    private func findWeb(in view: UIView) -> WKWebView? {
        (view as? WKWebView) ?? view.subviews.lazy.compactMap { findWeb(in: $0) }.first
    }
}
