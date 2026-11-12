import Foundation
import Testing
@testable import yuedu_app

@Suite("S7 WebDAV恢复事务", .serialized)
@MainActor
struct WebDAVRestoreSafetyTests {
    private enum Injected: Error { case interrupted }

    @Test("其他分类写入期间RSS旧票据失效且不发新票据")
    func requestsCannotCrossRestoreBoundary() async throws {
        try await withLocal { owner, file, local in
            let source = RSSSource(id: "original", name: "Original", url: "https://original.invalid/rss")
            owner.addSource(source)
            try await owner.flushPersistence()
            let ticket = try #require(owner.requestTicket(for: source.id))
            var local = local
            local.afterCategoryWrite = { category in
                guard category == .bookSources else { return }
                await MainActor.run {
                    #expect(!owner.accepts(ticket), "事务开始即撤销晚到请求，不能等到RSS分类才失效")
                    #expect(owner.requestTicket(for: source.id) == nil, "落盘挂起期间不能开始新刷新")
                }
            }
            let empty = try await RSSBackupCodec.encode(sources: [], folders: [], records: [:], statuses: [:])
            try await local.apply([(.bookSources, Data("[]".utf8)), (.rss, empty)])
            #expect(owner.sources.isEmpty)
            #expect(try Data(contentsOf: file) == Data("[]".utf8))
        }
    }

    @Test("RSS分类已经落盘后失败仍恢复原正文变量状态与其他分类精确字节")
    func failureAfterRSSWriteRestoresOwnerAndFiles() async throws {
        try await withLocal { owner, file, local in
            let source = RSSSource(id: "original", name: "Original", url: "https://original.invalid/rss")
            owner.addSource(source)
            let article = RSSItem(id: "article", title: "Original", link: "https://original.invalid/article",
                contentHTML: "<p>original body</p>", sourceId: source.id)
            owner.mergeFetchedItems([article], for: source.id)
            owner.toggleFavorite(articleId: article.id)
            owner.setVariables(["original": "synthetic-value"], for: source.id)
            try await owner.flushPersistence()
            let before = try #require(owner.article(id: article.id))
            let bytes = try Data(contentsOf: file)
            var local = local
            local.afterCategoryWrite = { category in
                if category == .rss { throw Injected.interrupted }
            }
            let empty = try await RSSBackupCodec.encode(sources: [], folders: [], records: [:], statuses: [:])
            await #expect(throws: Injected.self) {
                try await local.apply([(.bookSources, Data("[]".utf8)), (.rss, empty)])
            }
            #expect(try Data(contentsOf: file) == bytes)
            #expect(owner.article(id: article.id) == before)
            #expect(owner.variables(for: source.id) == ["original": "synthetic-value"])
            try await owner.flushPersistence()
            let reloaded = RSSStore(storageDirectory: file.deletingLastPathComponent().appendingPathComponent("rss"))
            #expect(reloaded.article(id: article.id) == before)
            #expect(reloaded.variables(for: source.id) == ["original": "synthetic-value"])
            #expect(owner.requestTicket(for: source.id) != nil, "回滚完成后恢复正常请求能力")
        }
    }

    @Test("owner发布前失败仍精确回滚全部分类并保留原RSS运行数据")
    func failureBeforeOwnerPublicationRestoresOriginals() async throws {
        try await withLocal { owner, file, local in
            let source = RSSSource(id: "original", name: "Original", url: "https://original.invalid/rss")
            owner.addSource(source)
            let article = RSSItem(id: "article", title: "Original", link: "https://original.invalid/article",
                contentHTML: "<p>original body</p>", sourceId: source.id)
            owner.mergeFetchedItems([article], for: source.id)
            owner.setVariables(["original": "synthetic-value"], for: source.id)
            try await owner.flushPersistence()
            let oldArticle = try #require(owner.article(id: article.id))
            let oldFile = try Data(contentsOf: file)
            var local = local
            local.beforeStoreReload = { throw Injected.interrupted }
            let replacement = try await RSSBackupCodec.encode(sources: [], folders: [], records: [:], statuses: [:])
            await #expect(throws: Injected.self) {
                try await local.apply([(.bookSources, Data("[]".utf8)), (.rss, replacement)])
            }
            #expect(try Data(contentsOf: file) == oldFile)
            #expect(owner.article(id: article.id) == oldArticle)
            #expect(owner.variables(for: source.id) == ["original": "synthetic-value"])
            #expect(!FileManager.default.fileExists(atPath: local.recoveryDirectory.appendingPathComponent("active.json").path))
        }
    }

    private func withLocal(_ body: (RSSStore, URL, WebDAVProductionLocalData) async throws -> Void) async throws {
        let directory = URL.temporaryDirectory.appendingPathComponent("WebDAVRestoreSafetyTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { do { try FileManager.default.removeItem(at: directory) } catch { Issue.record(error) } }
        let file = directory.appendingPathComponent("book_sources.json")
        try Data(" [ ]\n".utf8).write(to: file)
        let owner = RSSStore(storageDirectory: directory.appendingPathComponent("rss"))
        let local = WebDAVProductionLocalData(rss: owner, bookStore: nil,
            fileOverrides: [.bookSources: file], recoveryDirectory: directory.appendingPathComponent("journal"))
        try await body(owner, file, local)
    }
}
