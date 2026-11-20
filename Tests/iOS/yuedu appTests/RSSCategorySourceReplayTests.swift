import Foundation
import Testing
@testable import yuedu_app

/// 私有规则与已捕获响应的离线重放；不发布源包，不加载网页、媒体或真实登录状态。
@Suite("RSS category source local replay", .serialized,
       .enabled(if: ProcessInfo.processInfo.environment["RSS_CATEGORY_REPLAY_INPUT"] != nil))
@MainActor
struct RSSCategorySourceReplayTests {
    private struct Input: Decodable, Sendable {
        var source: RSSSource
        var body: Data
        var listBody: Data
    }

    @Test("原分类脚本取得合法JSON后成功生成分类，保留下一阶段的页码模板")
    func resolvesOriginalCategoryScript() async throws {
        let path = try #require(ProcessInfo.processInfo.environment["RSS_CATEGORY_REPLAY_INPUT"])
        let input = try await Task.detached {
            try JSONDecoder().decode(Input.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        }.value
        let (expectedCount, expectedItems) = try await Task.detached {
            let value = try #require(try JSONSerialization.jsonObject(with: input.body) as? [String: Any])
            let count = try #require(value["rescont"] as? [[String: Any]]).count
            let page = try #require(try JSONSerialization.jsonObject(with: input.listBody) as? [String: Any])
            let content = try #require(page["rescont"] as? [String: Any])
            return (count, try #require(content["data"] as? [[String: Any]]).count)
        }.value
        let originalURL = try #require(URL(string: input.source.url))
        let scheme = try #require(originalURL.scheme)
        let originalHost = try #require(originalURL.host)
        let originalOrigin = scheme + "://" + originalHost
        let host = "categories-replay-\(UUID().uuidString.lowercased()).invalid"
        var source = input.source
        source.id = UUID().uuidString
        source.url = "https://\(host)/"
        source.sortUrl = source.sortUrl?.replacingOccurrences(of: originalOrigin, with: "https://\(host)")
        let session = RSSPageFixtureProtocol.makeSession()
        RSSPageFixtureProtocol.serve(host: host, sequences: [
            "/api/videosort": [.init(body: input.body, contentType: "application/json")],
            "/api/videosort/0": [.init(body: input.listBody, contentType: "application/json")]
        ])
        defer { session.invalidateAndCancel(); RSSPageFixtureProtocol.remove(host: host) }

        let categories = try await LegadoRSSScraper.resolveSortEntries(for: source, requestSession: session)
        #expect(categories.count == expectedCount)
        #expect(categories.filter { $0.url.contains("{{page}}") }.count == expectedCount)
        #expect(categories.first?.url.contains("{{source.getVariable()}}") == true)
        #expect(RSSPageFixtureProtocol.requests(host: host).count == 1)
        #expect(RSSPageFixtureProtocol.requests(host: host).first?.url?.path == "/api/videosort")
        let entry = try #require(categories.first)
        let page = try await LegadoRSSScraper.fetchListPage(source: source, entry: entry, requestSession: session)
        #expect(page.items.count == expectedItems)
        #expect(page.items.first?.variables?.keys.contains("pic") == true)
        #expect(RSSPageFixtureProtocol.requests(host: host).count == 2)
        #expect(RSSPageFixtureProtocol.requests(host: host).last?.url?.query == "page=1&serach=")
    }
}
