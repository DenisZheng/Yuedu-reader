import Foundation
import Testing
import UIKit
@testable import yuedu_app

/// 仅复用 R161 的规则形态。域名、分类、数据与图片均为自建样本，不读原包或请求外站。
@Suite("RSS JSON rule list opening", .serialized)
@MainActor
struct RSSRuleListOpeningTests {
    @Test("图片流批量读取写入有符号字节，支持偏移、短读与 EOF")
    func imageDecodeBulkReadUsesBuffer() async throws {
        let decoded = await SourceScriptThread.run {
            JSCoreEngine().evaluateBytes(#"""
            const buffer = java.strToBytes('~~~~');
            if (result[0] !== 255 || result.read() !== 255) throw new Error('single read');
            if (result.read(buffer, 1, 2) !== 2 || buffer[0] !== 126 ||
                buffer[1] !== -128 || buffer[2] !== 7 || buffer[3] !== 126) throw new Error('offset read');
            const out = new Packages.java.io.ByteArrayOutputStream();
            out.write(buffer, 1, 2);
            if (result.read(buffer, 0, 0) !== 0 || result.read(buffer) !== 1 || buffer[0] !== 33 ||
                result.read(buffer) !== -1 || result.read() !== -1) throw new Error('short read or EOF');
            out.write(buffer, 0, 1);
            out.toByteArray();
            """#, data: Data([255, 128, 7, 33]))
        }
        #expect(decoded == Data([128, 7, 33]))
    }

    @Test("随机页分类正常生成请求、解析 JSON 条目并解码封面")
    func randomPageJSONListAndCover() async throws {
        let host = "rss-json-\(UUID().uuidString.lowercased()).invalid"
        let directory = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let session = RSSPageFixtureProtocol.makeSession()
        let png = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
        let json = #"{"rescont":{"data":[{"id":"one","title":"Fixture title REMOVE","updated_at":"2026-11-27 09:00:00","playtimes":3,"coverbase64":{"url":"/cover"}}],"next_page_url":"/api/v1/list?page=2"}}"#
        RSSPageFixtureProtocol.serve(host: host, sequences: [
            "/api/v1/random": [.init(body: Data(json.utf8), contentType: "application/json")],
            "/cover": [.init(body: Data("data:image/png;base64,\(png)".utf8), contentType: "text/plain")]
        ])
        defer {
            session.invalidateAndCancel()
            RSSPageFixtureProtocol.remove(host: host)
            do { try FileManager.default.removeItem(at: directory) } catch { Issue.record(error) }
        }
        let store = RSSStore(storageDirectory: directory)
        var source = RSSSource(name: "JSON list fixture", url: "https://\(host)/")
        source.importedFromLegado = true
        source.enabledCookieJar = true
        source.sortUrl = "\n推薦::/api/v1/random?page={{ Math.ceil(Math.random()*1500) }}\n最新::/api/v1/list?page={{page}}"
        source.header = #"{"User-Agent":"RSSFixture/1","referer":"{{baseUrl}}"}"#
        source.ruleArticles = "$.rescont.data[*]"
        source.ruleTitle = "$.title##REMOVE|OMIT"
        source.ruleLink = "watch/{{$.id}}?from=fixture"
        source.ruleImage = "{{$.coverbase64.url}}"
        source.rulePubDate = "📆{{$.updated_at## .*}}  ⏱️{{$.playtimes}}"
        source.ruleNextPage = "$.rescont.next_page_url"
        source.coverDecodeJs = """
        var stream = new Packages.java.io.ByteArrayOutputStream();
        var buffer = java.strToBytes(' '.repeat(4096));
        var count;
        while ((count = result.read(buffer)) !== -1) stream.write(buffer, 0, count);
        var text = java.bytesToStr(stream.toByteArray(), 'UTF-8');
        java.base64DecodeToByteArray(text.substring(text.indexOf(',') + 1));
        """
        store.addSource(source)
        let browser = RSSFeedSession(source: source, store: store, session: session)
        await browser.refresh()

        let requests = RSSPageFixtureProtocol.requests(host: host)
        #expect(requests.count == 1)
        let request = try #require(requests.first)
        #expect(request.url?.path == "/api/v1/random")
        let query = try #require(request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }?.queryItems?.first)
        let random = try #require(query.value.flatMap(Int.init))
        #expect(query.name == "page" && (0...1500).contains(random))
        try #require(browser.error == nil && browser.currentPage == 1)
        let articles = store.articles(for: source.id, scope: browser.scope)
        #expect(articles.count == 1)
        let item = try #require(articles.first)
        #expect(item.title == "Fixture title")
        #expect(item.link == "https://\(host)/api/v1/watch/one?from=fixture")
        #expect(item.imageURL == "https://\(host)/cover")
        #expect(browser.nextURL == "https://\(host)/api/v1/list?page=2")
        let image = try await RSSImageService.thumbnail(item, source: source, owner: store, session: session)
        #expect(image.size.width == 1 && image.size.height == 1)
        #expect(RSSPageFixtureProtocol.requests(host: host).map { $0.url?.path } == ["/api/v1/random", "/cover"])
        try await store.flushPersistence()
    }
}
