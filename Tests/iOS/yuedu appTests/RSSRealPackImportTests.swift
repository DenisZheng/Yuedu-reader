import Foundation
import Testing
@testable import yuedu_app

/// 只在S2验收入口显式选择；从宿主工作区读取原包，不复制到测试Bundle，不运行脚本/请求。
@Suite("S2 offline real RSS pack audit", .serialized)
struct RSSRealPackImportTests {
    @MainActor
    @Test("307项原始配置经过实际导入、磁盘重载、导出逐字段一致")
    func offlineFullPack() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let url = root.appendingPathComponent("docs/rssSources-valid.json")
        let data = try Data(contentsOf: url)
        let original = try #require(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        let loaded = try await RSSImportService.load(.file(url))
        let count = loaded.candidates.filter { $0.source != nil }.count
        #expect(original.count == 307 && count == 307)
        #expect(loaded.requests == 0)
        #expect(loaded.candidates.allSatisfy { $0.issue == nil })
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {
            do { try FileManager.default.removeItem(at: folder) }
            catch { Issue.record("无法清理隔离审计目录") }
        }
        let store = RSSStore(storageDirectory: folder)
        let plan = try await RSSImportService.compare(loaded, with: store.importSnapshot())
        #expect(plan.additions == 307 && plan.errors == 0 && plan.skips == 0)
        let changes = try await RSSImportService.changes(for: plan, selected: plan.initialSelection)
        try await store.commitImport(changes)
        let persisted = RSSStore(storageDirectory: folder)
        let exported = try LegadoSourceJSONParser.export(sources: persisted.sources)
        let objects = try #require(JSONSerialization.jsonObject(with: exported) as? [[String: Any]])
        #expect(objects.count == 307)
        var mismatches = 0
        for (before, after) in zip(original, objects) {
            for (key, value) in before {
                if !NSDictionary(dictionary: ["v": value]).isEqual(to: after[key].map { ["v": $0] } ?? [:]) { mismatches += 1 }
            }
        }
        // 不将原始字段值交给Testing宏（失败时会输出请求/脚本）。
        #expect(mismatches == 0)
        let fields = Set(original.flatMap { $0.keys })
        #expect(fields.subtracting(LegadoSourceJSONParser.knownFields).isEmpty)
        #expect(store.writeCounts["rss_sources.json"] == 1)
        let ids = persisted.sources.map(\.id)
        let repeatPlan = try await RSSImportService.compare(loaded, with: persisted.importSnapshot())
        #expect(repeatPlan.skips == 307 && repeatPlan.updates == 0)
        #expect(ids == persisted.sources.map(\.id))
        print("S2离线审计：307项，\(fields.count)个已识别配置字段，0字段差异，0脚本执行/网络请求")
    }
}
