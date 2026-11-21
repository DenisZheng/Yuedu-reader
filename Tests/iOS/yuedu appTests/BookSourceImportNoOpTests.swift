import Combine
import Foundation
import Testing
@testable import yuedu_app

/// 自建源和独立目录验证真实导入事务，不修改共享书源库或用户源包。
@Suite("书源导入不变不写", .serialized)
@MainActor
struct BookSourceImportNoOpTests {
    @Test("重复导入相同内容不写盘、不发布，忽略输入身份和作者时钟")
    func identicalImportKeepsFileAndRevision() async throws {
        try await withStore { store, directory in
            let original = self.source("Original", index: 1)
            store.replaceSourcesFromSync([original])
            await store.queuedWritesLanded()
            let before = try await self.fileNumber(directory)
            let writes = DiskWriteTally.total(BookSourceStore.diskWriteTallyName)
            let revision = store.mutationRevision
            var publications = 0
            let observation = store.sourcesPublisher.dropFirst().sink { _ in publications += 1 }
            defer { observation.cancel() }
            var incoming = original
            incoming.id = UUID()
            incoming.lastUpdateTime = 42
            for _ in 0..<3 {
                #expect(try store.importFromJSON(self.json([incoming])) == 1)
                await store.queuedWritesLanded()
            }
            #expect(try await self.fileNumber(directory) == before)
            #expect(DiskWriteTally.total(BookSourceStore.diskWriteTallyName) == writes)
            #expect(store.mutationRevision == revision)
            #expect(publications == 0)
            #expect(store.source(id: original.id)?.lastUpdateTime == original.lastUpdateTime)
            #expect(store.sources.count == 1)
        }
    }

    @Test("保留本地名称、分组、开关和排序后相同的确认导入也不写盘")
    func retainedOptionsAreNoOp() async throws {
        try await withStore { store, directory in
            var original = self.source("Local", index: 1)
            original.bookSourceGroup = "Local group"
            original.enabled = false; original.enabledExplore = false; original.customOrder = 7
            store.replaceSourcesFromSync([original])
            await store.queuedWritesLanded()
            let before = try await self.fileNumber(directory)
            let revision = store.mutationRevision
            var incoming = original
            incoming.id = UUID(); incoming.lastUpdateTime = 1
            incoming.bookSourceName = "Incoming"; incoming.bookSourceGroup = "Incoming group"
            incoming.enabled = true; incoming.enabledExplore = true; incoming.customOrder = 0
            let options = BookSourceImportOptions(keepName: true, keepGroup: true,
                keepEnable: true, keepCustomOrder: true)
            #expect(try store.importSelected([incoming], options: options) == 1)
            await store.queuedWritesLanded()
            #expect(try await self.fileNumber(directory) == before)
            #expect(store.mutationRevision == revision)
            #expect(store.sources.first?.id == original.id)
            #expect(store.sources.first?.hasSameContent(as: original) == true)
        }
    }

    @Test("一个源修改、一个源新增仍落盘，重复URL最后一项生效且原身份不变")
    func changedAndAddedSourcesStillPersist() async throws {
        try await withStore { store, directory in
            let original = self.source("Original", index: 1)
            let untouched = self.source("Untouched", index: 2)
            store.replaceSourcesFromSync([original, untouched])
            await store.queuedWritesLanded()
            let before = try await self.fileNumber(directory)
            let revision = store.mutationRevision
            var edited = original
            edited.id = UUID(); edited.bookSourceComment = "Changed fixture"
            var later = edited
            later.bookSourceComment = "Final fixture"
            let added = self.source("New", index: 3)
            #expect(try store.importSelected([edited, later, untouched, added], options: .direct) == 4)
            await store.queuedWritesLanded()
            #expect(try await self.fileNumber(directory) != before)
            #expect(store.mutationRevision == revision + 1)
            #expect(store.sources.map(\.id).prefix(2) == [original.id, untouched.id])
            let saved = try #require(store.source(id: original.id))
            #expect(saved.bookSourceComment == "Final fixture")
            #expect(saved.lastUpdateTime > original.lastUpdateTime)
            #expect(store.source(id: untouched.id)?.lastUpdateTime == untouched.lastUpdateTime)
            #expect(store.sources.count == 3)
            let expected = store.sources
            let persisted = try await Task.detached {
                try JSONDecoder().decode([BookSource].self,
                    from: Data(contentsOf: directory.appendingPathComponent("book_sources.json")))
            }.value
            #expect(persisted.map(\.id) == expected.map(\.id))
            #expect(persisted.first?.bookSourceComment == "Final fixture")
        }
    }

    private func source(_ name: String, index: Int) -> BookSource {
        var value = BookSource(bookSourceUrl: "https://import-fixture.invalid/\(index)", bookSourceName: name)
        value.lastUpdateTime = 1_000
        value.searchUrl = "/search?query={{key}}"
        value.ruleSearch.bookList = ".book"
        return value
    }

    private func json(_ sources: [BookSource]) throws -> String {
        String(decoding: try JSONEncoder().encode(sources), as: UTF8.self)
    }

    private func fileNumber(_ directory: URL) async throws -> UInt64 {
        try await Task.detached {
            let url = directory.appendingPathComponent("book_sources.json")
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            return try #require(attributes[.systemFileNumber] as? NSNumber).uint64Value
        }.value
    }

    private func withStore(_ body: (BookSourceStore, URL) async throws -> Void) async throws {
        let directory = URL.temporaryDirectory.appendingPathComponent("import-no-op-\(UUID().uuidString)")
        try await Task.detached {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }.value
        let store = BookSourceStore(directory: directory)
        do {
            try await body(store, directory)
            await store.queuedWritesLanded()
            try await Task.detached { try FileManager.default.removeItem(at: directory) }.value
        } catch {
            await store.queuedWritesLanded()
            do { try await Task.detached { try FileManager.default.removeItem(at: directory) }.value }
            catch { Issue.record(error) }
            throw error
        }
    }
}
