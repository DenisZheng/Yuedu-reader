import Foundation
import Testing
@testable import yuedu_app

private final class RSSAlignmentFixtureBundle {}

/// 固定输入基线：保留当前差异供后续阶段替换为对齐合同，不等于这些字段/入口已兼容。
@Suite("RSS alignment fixture baseline", .serialized)
struct RSSAlignmentFixtureTests {
    private func fixture() throws -> [[String: Any]] {
        let file = try #require(Bundle(for: RSSAlignmentFixtureBundle.self)
            .url(forResource: "rss-alignment-sources", withExtension: "json"))
        return try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [[String: Any]])
    }

    @Test("合成源均可导入且保留原始sourceKey，导入不执行脚本")
    func importAndIdentity() throws {
        let raw = try fixture()
        let data = try JSONSerialization.data(withJSONObject: raw)
        let sources = try LegadoSourceJSONParser.parse(data: data)
        #expect(sources.count == 8)
        #expect(sources.map(\.url) == raw.compactMap { $0["sourceUrl"] as? String })
        let exported = try LegadoSourceJSONParser.export(sources: sources)
        let roundTrip = try LegadoSourceJSONParser.parse(data: exported)
        #expect(roundTrip.map(\.url) == sources.map(\.url))
    }

    @Test("S1差异记录：singleUrl混合规则当前误入列表，S5必须改为动态单页入口")
    func mixedSingleURLBaseline() throws {
        let source = try #require(LegadoSourceJSONParser.parse(data: JSONSerialization.data(withJSONObject: fixture())).first)
        #expect(source.singleUrl)
        #expect(!source.opensAsWebPage)
        #expect(source.isLegadoRuleBased)
    }

    @Test("S1差异记录：类型/启动/搜索/变量/未知字段当前丢失，S2必须补齐round-trip")
    func missingFieldBaseline() throws {
        let raw = try fixture()
        let sources = try LegadoSourceJSONParser.parse(data: JSONSerialization.data(withJSONObject: raw))
        let exported = try LegadoSourceJSONParser.export(sources: sources)
        let objects = try #require(JSONSerialization.jsonObject(with: exported) as? [[String: Any]])
        let missing = Set(zip(raw, objects).flatMap { original, result in
            original.keys.filter { result[$0] == nil }
        })
        #expect(missing == Set(["type", "startHtml", "startStyle", "startJs", "nextContentUrl", "searchUrl", "variable", "futureField", "cacheFirst", "showWebLog", "preloadJs"]))
    }

    @Test("解析层确实保留短交互description；阅读层不得因长度覆盖它")
    func interactiveDescriptionParserBaseline() throws {
        let sources = try LegadoSourceJSONParser.parse(data: JSONSerialization.data(withJSONObject: fixture()))
        let source = try #require(sources.first { $0.name == "S1-interactive-description" })
        let body = """
        <div class="item"><a href="/article/one">Synthetic article</a>
          <div class="description"><button onclick="window.fixtureClicked=true">Play</button><iframe src="/player"></iframe></div>
        </div>
        """
        let items = try LegadoRSSScraper.parseArticles(body: body, finalURL: source.url, listRule: "class.item", reverse: false, source: source, jsEngine: JSCoreEngine())
        let item = try #require(items.first)
        #expect(items.count == 1)
        #expect(item.link == "https://fixture.invalid/article/one")
        #expect(item.contentHTML.contains("iframe"))
        #expect(item.contentHTML.contains("fixtureClicked"))
    }
}
