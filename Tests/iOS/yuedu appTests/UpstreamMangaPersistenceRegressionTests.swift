import Foundation
import Testing
@testable import yuedu_app

/// 重现FB-183：开书后在同一章内翻页，退后台落盘后重启仍停在旧页。
@Suite("上游首批漫画落盘回归", .serialized)
@MainActor struct UpstreamMangaPersistenceRegressionTests {
    @Test("开书刚落盘后同章页码变化仍写盘，不等待60秒元数据上限")
    func pageTurnImmediatelyAfterOpenSurvivesReload() async throws {
        let directory = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { do { try FileManager.default.removeItem(at: directory) } catch { Issue.record(error) } }
        let file = directory.appendingPathComponent("books_meta.json")
        let store = BookStore(metadataFileURL: file)
        var book = ReadingBook(title: "Fixture", author: "", contentFilename: "")
        book.isOnline = true
        book.onlineChapters = (0..<3).map { OnlineChapterRef(index: $0, title: "Chapter \($0)", url: "https://example.invalid/\($0)") }
        store.replaceBooksFromSync([book])
        await BookStore.queuedWritesLanded()
        store.updateLastOpened(bookId: book.id)
        store.flushPendingMetadataSave()
        await BookStore.queuedWritesLanded()
        store.updateMangaPosition(bookId: book.id, chapter: 0, page: 5, totalChapters: 3, notifyLibraryViews: false)
        store.flushPendingMetadataSave()
        await BookStore.queuedWritesLanded()
        let reopened = BookStore(metadataFileURL: file)
        #expect(reopened.readingBook(id: book.id)?.mangaPage == 5)
    }
}
