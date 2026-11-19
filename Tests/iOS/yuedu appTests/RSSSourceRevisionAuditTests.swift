import Foundation
import XCTest
@testable import yuedu_app

/// 自建站点改版DOM，经生产请求／规则／store验证；不依赖源包或私有捕获文件。
@MainActor
final class RSSSourceRevisionAuditTests: XCTestCase {
    func testConfigurationRevisionPreservesOriginalFailureAndRecovers() async throws {
        let html = """
        <div class="article-item">
          <a class="article-item__thumb" href="/one"><img src="/one.webp"></a>
          <div class="article-item__content"><h3 class="article-item__title"><a href="/one">One</a></h3></div>
        </div>
        <div class="article-item">
          <a class="article-item__thumb" href="/two"><img src="/two.png"></a>
          <div class="article-item__content"><h3 class="article-item__title"><a href="/two">Two</a></h3></div>
        </div>
        """
        let server = try VideoStillFixtureServer(directory: .temporaryDirectory, routes: [
            "/list": .init(body: Data(html.utf8), type: "text/html; charset=utf-8")
        ])
        let base = try await server.start()
        let directory = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {
            server.stop()
            do { try FileManager.default.removeItem(at: directory) }
            catch { XCTFail("无法清理隔离规则修订目录") }
        }
        let store = RSSStore(storageDirectory: directory)
        var original = RSSSource(name: "Synthetic revision", url: base.appendingPathComponent("list").absoluteString)
        original.singleUrl = false
        original.ruleArticles = ".item"
        original.ruleTitle = "tag.a.2@text"
        original.ruleLink = "tag.a.2@href"
        original.ruleImage = "tag.img@data-original"
        store.addSource(original)
        let browser = RSSFeedSession(source: original, store: store, maxPages: 1)
        await browser.refresh()
        XCTAssertNil(browser.error)
        XCTAssertEqual(browser.currentPage, 1)
        XCTAssertEqual(browser.end, .empty)
        XCTAssertTrue(store.articles(for: original.id, scope: browser.scope).isEmpty,
                      "旧规则不能自动猜成新类名；原失效行为必须保留")
        let ticket = try XCTUnwrap(store.requestTicket(for: original.id))
        let revision = S8R217ReviewedRevision.applying(to: original)
        store.updateSource(revision)
        XCTAssertFalse(store.accepts(ticket))
        XCTAssertEqual(store.source(id: original.id)?.id, original.id)
        await browser.refresh()
        XCTAssertNil(browser.error)
        XCTAssertEqual(browser.currentPage, 1)
        let articles = store.articles(for: original.id, scope: browser.scope)
        XCTAssertEqual(Set(articles.map(\.title)), ["One", "Two"])
        XCTAssertEqual(Set(articles.compactMap(\.imageURL)),
                       Set([base.appendingPathComponent("one.webp").absoluteString, base.appendingPathComponent("two.png").absoluteString]))
        XCTAssertEqual(Set(articles.map(\.link)),
                       Set([base.appendingPathComponent("one").absoluteString, base.appendingPathComponent("two").absoluteString]))
        XCTAssertFalse(browser.canLoadMore)
        XCTAssertEqual(server.requests.map(\.path), ["/list", "/list"], "配置修订不自动请求图片／正文或额外页面")
        try await store.flushPersistence()
        let restored = RSSStore(storageDirectory: directory)
        XCTAssertEqual(restored.source(id: original.id)?.ruleArticles, revision.ruleArticles)
        XCTAssertEqual(restored.source(id: original.id)?.ruleImage, revision.ruleImage)
        XCTAssertEqual(restored.articles(for: original.id, scope: browser.scope).count, 2)
    }
}
