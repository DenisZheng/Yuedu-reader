import Foundation
import SwiftUI
import Testing
import UIKit
import WebKit
@testable import yuedu_app

/// 用预审过的私有电影规则重放首个条目，所有可加载资源均替换为本机 fixture。
/// 不复制源包到测试资源，不运行分类批量请求、登录动作或外部解析服务。
@Suite("RSS movie page local replay", .serialized,
       .enabled(if: ProcessInfo.processInfo.environment["RSS_MOVIE_REPLAY_INPUT"] != nil))
@MainActor
struct RSSMoviePageReplayTests {
    @Test("原电影规则的生成网页首次打开保持有效，无外部资源")
    func opensGeneratedMoviePage() async throws {
        let path = try #require(ProcessInfo.processInfo.environment["RSS_MOVIE_REPLAY_INPUT"])
        let input = try await Task.detached {
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            return try JSONDecoder().decode(RSSSource.self, from: data)
        }.value
        let directory = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let owner = RSSStore(storageDirectory: directory)
        let server = try VideoStillFixtureServer(directory: directory, routes: [
            "/frame": .init(body: Data("<p id='frame'>Local player frame</p>".utf8)),
            "/poster.png": .init(body: Data(), type: "image/png")
        ])
        let base = try await server.start()
        defer { server.stop() }
        var source = input
        source.id = UUID().uuidString
        source.sourceComment = "api='\(base.appendingPathComponent("article").absoluteString)';"
        source.homepageURL = "https://127.0.0.1:9/"
        source.sourceIcon = base.appendingPathComponent("poster.png").absoluteString
        source.faviconURL = source.sourceIcon
        let snapshot = source
        owner.addSource(snapshot)
        let row: [String: Any] = [
            "vod_id": "fixture", "vod_name": "Movie local replay", "vod_play_from": "Local",
            "vod_play_url": "Episode$" + base.appendingPathComponent("frame").absoluteString,
            "vod_pic": base.appendingPathComponent("poster.png").absoluteString,
            "vod_content": "Local fixture", "vod_time": "2026-01-01 00:00:00"
        ]
        let body = String(decoding: try JSONSerialization.data(withJSONObject: ["list": [row]]), as: UTF8.self)
        let runtime = try await RSSRuntime.make(source: source, owner: owner)
        let items = try await runtime.run { host in
            try await host.run { bridge in
                try LegadoRSSScraper.parseArticles(body: body, finalURL: base.appendingPathComponent("list").absoluteString,
                    listRule: "$.list", reverse: false, source: snapshot, bridge: bridge)
            }
        }
        try #require(items.count == 1)
        owner.mergeFetchedItems(items, for: source.id)
        let article = try #require(owner.article(id: items[0].id))
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: NavigationStack {
            RSSArticleReaderView(articleID: article.id, store: owner)
        })
        window.isHidden = false
        defer { window.isHidden = true; window.rootViewController = nil }
        let deadline = ContinuousClock.now + .seconds(12)
        while findWeb(window) == nil, ContinuousClock.now < deadline { await Task.yield() }
        let web = try #require(findWeb(window))
        while (web.isLoading || server.requests.allSatisfy { $0.path != "/frame" }), ContinuousClock.now < deadline {
            await Task.yield()
        }
        #expect(web.configuration.defaultWebpagePreferences.allowsContentJavaScript)
        #expect(runtime.state.isCurrent)
        #expect(try await web.evaluateJavaScript("document.querySelector('iframe') !== null") as? Bool == true)
        #expect(server.requests.contains { $0.path == "/frame" })
        window.isHidden = true; window.rootViewController = nil
        try await owner.flushPersistence()
        do { try FileManager.default.removeItem(at: directory) } catch { Issue.record(error) }
    }

    private func findWeb(_ view: UIView) -> WKWebView? {
        (view as? WKWebView) ?? view.subviews.lazy.compactMap(findWeb).first
    }
}
