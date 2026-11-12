import Foundation
import Testing
@testable import yuedu_app

@Suite("S7 WebDAV已提交快照重载", .serialized)
@MainActor
struct WebDAVRestoredShelfTests {
    @Test("分类恢复走生产用例与原owner，书架立即更新且本机阅读记录保留")
    func restoreUpdatesLiveShelfAndPreservesReadingRecords() async throws {
        try await withDirectory { directory in
            let file = directory.appendingPathComponent("books_meta.json")
            let original = ReadingBook(title: "Original", contentFilename: "")
            var readOnly = ReadingBook(title: "Reading only", contentFilename: "")
            readOnly.isInBookshelf = false
            readOnly.currentPosition = 0.42
            try JSONEncoder().encode([original]).write(to: file)
            let readingFile = BookStore.readingMetadataFileURL(forShelf: file)
            let readingBytes = try JSONEncoder().encode([readOnly])
            try readingBytes.write(to: readingFile)
            let store = BookStore(metadataFileURL: file)
            let restored = ReadingBook(title: "Restored", contentFilename: "")
            let bytes = try JSONEncoder().encode([restored])
            let local = WebDAVProductionLocalData(rss: RSSStore(storageDirectory: directory.appendingPathComponent("rss")),
                bookStore: store, fileOverrides: [.bookshelf: file], recoveryDirectory: directory.appendingPathComponent("journal"))
            try await local.apply([(.bookshelf, bytes)])
            #expect(store.books.map(\.id) == [restored.id])
            #expect(store.readingBook(id: readOnly.id)?.currentPosition == 0.42)
            #expect(store.readingBook(id: original.id) == nil)
            await BookStore.queuedWritesLanded()
            #expect(try Data(contentsOf: file) == bytes, "未修复摘要时不重写已提交文件")
            #expect(try Data(contentsOf: readingFile) == readingBytes)
            let reopened = BookStore(metadataFileURL: file)
            #expect(reopened.books.map(\.id) == [restored.id])
            #expect(reopened.readingBook(id: readOnly.id)?.currentPosition == 0.42)
        }
    }

    @Test("远端无章节摘要时从本机目录修复，保留章节身份并实际落盘")
    func restoredSummaryUsesExistingChapterOwner() async throws {
        try await withDirectory { directory in
            let file = directory.appendingPathComponent("books_meta.json")
            let store = BookStore(metadataFileURL: file)
            var book = ReadingBook(title: "Original", source: "https://fixture.invalid/book", contentFilename: "")
            book.isOnline = true
            book.contentPipelineKind = .html
            let chapters = [OnlineChapterRef(index: 0, title: "Chapter", url: "https://fixture.invalid/chapter")]
            book.onlineChapters = chapters
            store.replaceBooksFromSync([book])
            await BookStore.queuedWritesLanded()
            var incoming = book
            incoming.title = "Restored"
            incoming.onlineChapters = nil
            incoming.totalChapterNum = nil
            incoming.latestChapterTitle = nil
            let bytes = try JSONEncoder().encode([incoming])
            try bytes.write(to: file, options: .atomic)
            try await store.reloadRestoredShelf(bytes)
            #expect(store.books.first?.title == "Restored")
            #expect(store.books.first?.totalChapterNum == 1)
            #expect(store.chapters(for: book.id) == chapters)
            await BookStore.queuedWritesLanded()
            let reopened = BookStore(metadataFileURL: file)
            #expect(reopened.books.first?.totalChapterNum == 1)
            #expect(reopened.chapters(for: book.id) == chapters)
        }
    }

    @Test("准备期间书架被编辑时拒绝快照，保留用户的新变更")
    func shelfMutationDuringPreparationIsNotOverwritten() async throws {
        try await withDirectory { directory in
            let file = directory.appendingPathComponent("books_meta.json")
            let store = BookStore(metadataFileURL: file)
            let before = ReadingBook(title: "Original", contentFilename: "")
            store.replaceBooksFromSync([before])
            await BookStore.queuedWritesLanded()
            let incoming = ReadingBook(title: "Cloud", contentFilename: "")
            let bytes = try JSONEncoder().encode([incoming])
            try bytes.write(to: file, options: .atomic)
            let prepared = try await store.prepareRestoredShelf(bytes)
            let concurrent = ReadingBook(title: "Edited while restore decoded", contentFilename: "")
            store.replaceBooksFromSync([concurrent])
            #expect(throws: BookStore.RestoreConflict.self) { try store.applyRestoredShelf(prepared) }
            #expect(store.books.map(\.id) == [concurrent.id])
        }
    }

    @Test("重复书籍身份在修改任何目标之前拒绝")
    func duplicateBookIDsAreRejectedBeforeWriting() async throws {
        try await withDirectory { directory in
            let file = directory.appendingPathComponent("books_meta.json")
            let original = Data("[]".utf8)
            try original.write(to: file)
            let local = WebDAVProductionLocalData(rss: RSSStore(storageDirectory: directory.appendingPathComponent("rss")),
                bookStore: nil, fileOverrides: [.bookshelf: file], recoveryDirectory: directory.appendingPathComponent("journal"))
            let book = ReadingBook(title: "Duplicate", contentFilename: "")
            let invalid = try JSONEncoder().encode([book, book])
            await #expect(throws: WebDAVBackupError.corrupt(.bookshelf)) { try await local.apply([(.bookshelf, invalid)]) }
            #expect(try Data(contentsOf: file) == original)
            #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("journal/active.json").path))
        }
    }

    @Test("书源后台去重后的快照只发布，不重读或重写文件")
    func preparedSourcesPublishWithoutDiskReload() async throws {
        try await withDirectory { directory in
            let store = BookSourceStore(directory: directory)
            await store.waitUntilLoaded()
            var source = BookSource()
            source.bookSourceName = "Restored"
            source.bookSourceUrl = "https://fixture.invalid/source"
            let file = directory.appendingPathComponent("book_sources.json")
            let bytes = try JSONEncoder().encode([source])
            try bytes.write(to: file)
            let prepared = try await Task.detached {
                BookSourceStore.dedupedByURL(try JSONDecoder().decode([BookSource].self, from: bytes))
            }.value
            let revision = store.mutationRevision
            store.applyRestoredSources(prepared)
            #expect(store.sources.map(\.bookSourceUrl) == [source.bookSourceUrl])
            #expect(store.mutationRevision != revision)
            await store.queuedWritesLanded()
            #expect(try Data(contentsOf: file) == bytes)
        }
    }

    @Test("书源解析期间本地修改优先，过期快照不得覆盖")
    func preparedSourcesDoNotOverwriteConcurrentEdit() async throws {
        try await withDirectory { directory in
            let store = BookSourceStore(directory: directory)
            await store.waitUntilLoaded()
            var restored = BookSource()
            restored.bookSourceName = "Restored"
            restored.bookSourceUrl = "https://fixture.invalid/restored"
            let bytes = try JSONEncoder().encode([restored])
            let prepared = try await Task.detached {
                BookSourceStore.dedupedByURL(try JSONDecoder().decode([BookSource].self, from: bytes))
            }.value
            let revision = store.mutationRevision
            var edited = BookSource()
            edited.bookSourceName = "Edited while restore decoded"
            edited.bookSourceUrl = "https://fixture.invalid/edited"
            store.add(edited)
            #expect(!store.applyRestoredSources(prepared, expectedMutationRevision: revision))
            #expect(store.sources.map(\.bookSourceUrl) == [edited.bookSourceUrl])
            await store.queuedWritesLanded()
        }
    }

    private func withDirectory(_ body: (URL) async throws -> Void) async throws {
        let directory = URL.temporaryDirectory.appendingPathComponent("WebDAVRestoredShelfTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { do { try FileManager.default.removeItem(at: directory) } catch { Issue.record(error) } }
        try await body(directory)
    }
}
