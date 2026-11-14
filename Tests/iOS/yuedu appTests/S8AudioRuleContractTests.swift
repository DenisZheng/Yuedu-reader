import Foundation
import Testing
@testable import yuedu_app

/// 自建数据复现R141同类的“字段提取+@put其他字段”合同；不复制真实响应、URL或完整源脚本。
@Suite("S8 audio rule variable contract", .serialized)
struct S8AudioRuleContractTests {
    @Test("日期字段后的@put读取完整条目，不把音频JSONPath变成字面量；相邻条目不串值")
    func fieldPutReadsArticleContext() async throws {
        var source = RSSSource(name: "S8 audio rule fixture", url: "https://s8-audio-fixture.invalid/list")
        source.importedFromLegado = true
        source.ruleArticles = "$.datas"
        source.ruleTitle = "$.desc"
        source.ruleLink = "$.link"
        source.rulePubDate = "$.time@put:{audio:$.audioUrl}"
        source.ruleDescription = "<audio src=\"{{java.get('audio')}}\"></audio>"
        let body = """
        {"datas":[
          {"desc":"One","link":"https://s8-audio-fixture.invalid/one","time":"2026-11-13","audioUrl":"https://s8-audio-fixture.invalid/one.mp3"},
          {"desc":"Two","link":"https://s8-audio-fixture.invalid/two","time":"2026-11-12","audioUrl":"https://s8-audio-fixture.invalid/two.mp3"}
        ]}
        """
        let snapshot = source
        let runtime = try await RSSRuntime.make(source: snapshot)
        let items = try await runtime.run { host in
            try await host.run { bridge in
                try LegadoRSSScraper.parseArticles(body: body, finalURL: snapshot.url, listRule: "$.datas", reverse: false,
                    source: snapshot, bridge: bridge)
            }
        }
        #expect(items.count == 2)
        #expect(items.map { $0.variables?["audio"] } == ["https://s8-audio-fixture.invalid/one.mp3", "https://s8-audio-fixture.invalid/two.mp3"])
        #expect(items.first?.contentHTML == "<audio src=\"https://s8-audio-fixture.invalid/one.mp3\"></audio>")
        #expect(items.last?.contentHTML == "<audio src=\"https://s8-audio-fixture.invalid/two.mp3\"></audio>")
    }
}
