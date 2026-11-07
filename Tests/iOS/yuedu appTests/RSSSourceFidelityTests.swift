import Foundation
import Testing
@testable import yuedu_app

@Suite("S2 RSS source fidelity", .serialized)
struct RSSSourceFidelityTests {
    @Test("缺名仍保留原始key，不把请求选项或凭据变成显示名")
    func unnamedAndOpaqueKeys() throws {
        let keys = ["https://user:secret@fixture.invalid/path?token=private#part,{\"method\":\"POST\"}", "@js:java.get('private')", "opaque #key {{page}}"]
        for key in keys {
            let data = try JSONSerialization.data(withJSONObject: ["sourceUrl": key])
            let sources = try LegadoSourceJSONParser.parse(data: data)
            #expect(sources.count == 1)
            if let source = sources.first {
                #expect(source.url == key)
                #expect(!source.name.contains("secret") && !source.name.contains("private"))
                #expect(!source.name.isEmpty)
            }
        }
    }

    @Test("已知字段、未知嵌套值、显式null经过磁盘编码和导出仍保真")
    func allFieldsRoundTrip() throws {
        let input = Data(#"{"sourceUrl":"opaque#key","sourceName":"Fixture","type":9,"startHtml":"<p>x</p>","startStyle":"p{}","startJs":"void 0","nextContentUrl":"next","searchUrl":"?q={{key}}","variable":"{}","cacheFirst":true,"showWebLog":true,"preloadJs":"var n=1","preload":true,"enableReadRecord":false,"header":null,"future":{"array":[true,null,9007199254740993,1.25,"值"]}}"#.utf8)
        let original = try #require(JSONSerialization.jsonObject(with: input) as? NSDictionary)
        let sources = try LegadoSourceJSONParser.parse(data: input)
        let restored = try JSONDecoder().decode([RSSSource].self, from: JSONEncoder().encode(sources))
        let exported = try LegadoSourceJSONParser.export(sources: restored)
        let objects = try #require(JSONSerialization.jsonObject(with: exported) as? [NSDictionary])
        let result = try #require(objects.first)
        for key in original.allKeys {
            // 只输出字段名和布尔结果，不让源配置/凭据进入失败日志。
            let equal = NSDictionary(dictionary: ["value": result[key] ?? NSNull()])
                .isEqual(to: ["value": original[key]!]) && result[key] != nil
            #expect(equal, "字段往返不一致")
        }
    }

    @Test("外包_id不得与本地其他source身份冲突")
    func externalIDIsNotTrusted() throws {
        let data = Data(#"[{"sourceUrl":"one","sourceName":"One","_id":"shared"},{"sourceUrl":"two","sourceName":"Two","_id":"shared"}]"#.utf8)
        let sources = try LegadoSourceJSONParser.parse(data: data)
        #expect(Set(sources.map(\.id)).count == 2)
    }
}
