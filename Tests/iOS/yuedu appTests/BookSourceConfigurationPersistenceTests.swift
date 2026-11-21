import Foundation
import Testing
@testable import yuedu_app

@Suite("书源配置保存与编辑保真", .serialized)
@MainActor
struct BookSourceConfigurationPersistenceTests {
    @Test("导入、编辑、保存、重载和导出保留未知层级与原始sourceKey")
    func fullRoundTrip() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("BookSourceConfigurationTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            do { try FileManager.default.removeItem(at: root) }
            catch { Issue.record("测试目录清理失败") }
        }
        let key = "https://example.invalid/?q={{key}}#family"
        let raw = Data(#"{"bookSourceUrl":"https://example.invalid/?q={{key}}#family","bookSourceName":"原名称","mainJs":"元数据，不执行","futureOptions":{"enabled":true,"items":[1,null,"值"]},"ruleContent":{"content":"p@text","subContent":"aside@text"}}"#.utf8)
        let source = try JSONDecoder().decode(BookSource.self, from: raw)
        let store = BookSourceStore(directory: root); await store.waitUntilLoaded()
        try store.importSelected([source], options: .direct); try await store.persistPendingChanges()
        let loaded = BookSourceStore(directory: root); await loaded.waitUntilLoaded()
        let original = try #require(loaded.source(id: source.id))
        let editedJSON = original.importEditableJSON.replacingOccurrences(of: "原名称", with: "编辑名称").replacingOccurrences(of: "p@text", with: "main@html")
        let edited = try #require(BookSource.importParse(editedJSON: editedJSON))
        try loaded.importSelected([edited], options: .direct); try await loaded.persistPendingChanges()
        let reloaded = BookSourceStore(directory: root); await reloaded.waitUntilLoaded()
        let result = try #require(reloaded.source(id: source.id))
        #expect(result.bookSourceUrl == key && result.bookSourceName == "编辑名称")
        let object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(result)) as? [String: Any])
        #expect(object["mainJs"] as? String == "元数据，不执行")
        let future = try #require(object["futureOptions"] as? [String: Any])
        #expect(future["enabled"] as? Bool == true)
        #expect((future["items"] as? [Any])?.count == 3)
        let rule = try #require(object["ruleContent"] as? [String: Any])
        #expect(rule["content"] as? String == "main@html" && rule["subContent"] as? String == "aside@text")
    }

    @Test("双重编码规则扩展字段也保留，坏规则不能转成空规则成功")
    func encodedRule() throws {
        let raw = Data(#"{"bookSourceUrl":"https://example.invalid","ruleBookInfo":"{\"name\":\"h1@text\",\"future\":{\"keep\":true}}"}"#.utf8)
        let source = try JSONDecoder().decode(BookSource.self, from: raw)
        let object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(source)) as? [String: Any])
        #expect(((object["ruleBookInfo"] as? [String: Any])?["future"] as? [String: Bool])?["keep"] == true)
        #expect(throws: (any Error).self) {
            _ = try JSONDecoder().decode(BookSource.self, from: Data(#"{"bookSourceUrl":"https://example.invalid","ruleContent":"{bad}"}"#.utf8))
        }
    }
}
