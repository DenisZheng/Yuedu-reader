import SwiftUI
import Testing
import UIKit
@testable import yuedu_app

@Suite("RSS列表预取", .serialized)
@MainActor
struct RSSListPreloadTests {
    @Test("preload开启的瀑布流接近末尾会取下一页，不需再按载入更多")
    func masonryNearEndPreloads() async throws {
        let directory = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = RSSStore(storageDirectory: directory)
        let first = (0..<60).map { "<div class='item'><a href='/article/\($0)'>文章\($0)</a></div>" }.joined()
        let second = "<div class='item'><a href='/article/60'>末页文章</a></div>"
        let server = try VideoStillFixtureServer(directory: directory, routes: [
            "/list": .init(body: Data((first + "<a class='next' href='/next'>Next</a>").utf8), type: "text/html"),
            "/next": .init(body: Data(second.utf8), type: "text/html")
        ])
        let base = try await server.start()
        var source = RSSSource(name: "Preload fixture", url: base.appendingPathComponent("list").absoluteString)
        source.ruleArticles = "class.item"; source.ruleTitle = "a@text"; source.ruleLink = "a@href"
        source.ruleNextPage = "a.next@href"; source.preload = true; source.articleStyle = 3
        store.addSource(source)
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: NavigationStack { RSSFeedView(source: source, store: store) })
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true; window.rootViewController = nil; previous?.makeKeyAndVisible(); server.stop()
            do { try FileManager.default.removeItem(at: directory) } catch { Issue.record(error) }
        }
        let deadline = ContinuousClock.now + .seconds(10)
        while store.articles(for: source.id).count < 60, ContinuousClock.now < deadline { await Task.yield() }
        #expect(store.articles(for: source.id).count == 60)
        var scroll = verticalScroll(in: window)
        while scroll == nil, ContinuousClock.now < deadline { await Task.yield(); scroll = verticalScroll(in: window) }
        let list = try #require(scroll)
        list.setContentOffset(CGPoint(x: 0, y: max(0, list.contentSize.height - list.bounds.height)), animated: false)
        while !server.requests.contains(where: { $0.path == "/next" }), ContinuousClock.now < deadline { await Task.yield() }
        #expect(server.requests.filter { $0.path == "/next" }.count == 1)
        while store.articles(for: source.id).count < 61, ContinuousClock.now < deadline { await Task.yield() }
        #expect(store.articles(for: source.id).count == 61)
        try await store.flushPersistence()
    }

    @Test("自动预取失败保留目标，不因行再次出现而自动重试；手动重试仍可完成")
    func preloadFailureKeepsManualRetry() async throws {
        let host = "preload-retry-\(UUID().uuidString.lowercased()).invalid"
        let session = RSSPageFixtureProtocol.makeSession()
        RSSPageFixtureProtocol.serve(host: host, sequences: [
            "/first": [.init(body: Data("<div class='item'><a href='/a'>First</a></div><a class='next' href='/second'>Next</a>".utf8))],
            "/second": [.init(body: Data(), status: 503), .init(body: Data("<div class='item'><a href='/b'>Second</a></div>".utf8))]
        ])
        let directory = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { session.invalidateAndCancel(); RSSPageFixtureProtocol.remove(host: host); do { try FileManager.default.removeItem(at: directory) } catch { Issue.record(error) } }
        let store = RSSStore(storageDirectory: directory)
        var source = RSSSource(name: "Retry preload", url: "https://\(host)/first")
        source.ruleArticles = "class.item"; source.ruleTitle = "a@text"; source.ruleLink = "a@href"; source.ruleNextPage = "a.next@href"
        store.addSource(source)
        let browser = RSSFeedSession(source: source, store: store, session: session)
        await browser.refresh()
        await browser.preloadIfNeeded()
        #expect(browser.currentPage == 1 && browser.canRetry)
        await browser.preloadIfNeeded()
        #expect(RSSPageFixtureProtocol.requests(host: host).count == 2)
        await browser.retry()
        #expect(browser.currentPage == 2 && !browser.canRetry)
        #expect(store.articles(for: source.id).count == 2)
        try await store.flushPersistence()
    }

    private func verticalScroll(in view: UIView) -> UIScrollView? {
        if let scroll = view as? UIScrollView, scroll.contentSize.height > scroll.bounds.height + 100 { return scroll }
        return view.subviews.lazy.compactMap { self.verticalScroll(in: $0) }.first
    }
}
