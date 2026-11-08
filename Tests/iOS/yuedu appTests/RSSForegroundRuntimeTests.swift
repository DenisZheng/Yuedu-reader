import SwiftUI
import Testing
import UIKit
@testable import yuedu_app

/// 走实际Feed View的.task→fetcher→runtime→RSSStore，不用直接调用服务替代生产调用方。
@Suite("RSS foreground runtime ownership", .serialized)
@MainActor
struct RSSForegroundRuntimeTests {
    @Test("前台列表读取owner变量，脚本写入重建store后仍存在")
    func foregroundUsesPersistentOwner() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("rss-foreground-\(UUID().uuidString)")
        defer {
            do { try FileManager.default.removeItem(at: directory) }
            catch { Issue.record("测试目录清理失败") }
        }
        let store = RSSStore(storageDirectory: directory)
        let body = Data("<div class='item'><a href='/one'>One</a></div>".utf8)
        let server = try VideoStillFixtureServer(directory: directory, routes: ["/list": .init(body: body)])
        let base = try await server.start()
        defer { server.stop() }
        var source = RSSSource(name: "Foreground fixture", url: base.appendingPathComponent("list").absoluteString)
        source.ruleArticles = "class.item"
        source.ruleTitle = "@js:java.get('seed')"
        source.ruleLink = "a@href"
        source.jsLib = "java.put('foreground','written')"
        store.addSource(source)
        store.setVariables(["seed": "Configured"], for: source.id)
        let snapshot = source
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: NavigationStack { RSSFeedView(source: snapshot, store: store) })
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        // 有限等待业务结果，不用固定延时把未完成的请求假定为完成。
        let deadline = ContinuousClock.now + .seconds(5)
        while store.articles(for: source.id).first?.title != "Configured", ContinuousClock.now < deadline {
            await Task.yield()
        }
        #expect(server.requests.count == 1)
        #expect(store.articles(for: source.id).first?.title == "Configured")
        #expect(store.variables(for: source.id)["foreground"] == "written")
        try await store.flushPersistence()
        let restored = RSSStore(storageDirectory: directory)
        #expect(restored.variables(for: source.id)["foreground"] == "written")
    }
}
