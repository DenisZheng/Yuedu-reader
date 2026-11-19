import Foundation
import Testing
import UIKit
@testable import yuedu_app

/// 改编自上游 75381a89：反复切章后，分页器不能继续持有已被文档存储淘汰的所有排版。
/// 上游记录的 TestFlight AGA6UftGrSZehKw65KigEv8 / Crashlytics 17c788ce 是问题出处，
/// 本文件只用自建正文、隔离进度目录验证保留数量，不连接站点或改写用户书架。
@Suite("分页器完整排版保留上限", .serialized)
@MainActor
struct CoreTextPaginatorRetentionTests {
    private static let chapterCount = 30

    private static func chapterText(_ index: Int) -> String {
        String(repeating: "第\(index)章，「這是一段對話。」他說：「好的，我們走吧！」然後一起離開了。\n", count: 120)
    }

    @Test("前后遍历三十章后，完整排版保留数不超过文档存储容量")
    func retentionIsBoundedWhileReading() async throws {
        let paginator = CoreTextPaginator()
        try await withEngine(paginator: paginator) { engine in
            let before = MemoryFootprint.current()
            for spine in 0..<Self.chapterCount {
                engine.updateReadingPosition(.chapterStart(spine))
                let outcome = await engine.preloadChapter(at: spine)
                try #require(outcome.isReady)
            }
            for spine in stride(from: Self.chapterCount - 1, through: 0, by: -1) {
                engine.updateReadingPosition(.chapterStart(spine))
                let outcome = await engine.preloadChapter(at: spine)
                try #require(outcome.isReady)
            }
            let delta = (Double(MemoryFootprint.current()) - Double(before)) / 1_000_000
            print("排版保留观测 chapters=\(Self.chapterCount) kept=\(paginator.cachedLayoutCount) footprintDelta=\(String(format: "%.1f", delta))MB")
            #expect(paginator.cachedLayoutCount > 0)
            #expect(paginator.cachedLayoutCount <= ChapterDocumentStore.defaultCapacity)
        }
    }

    @Test("内存警告同时释放分页器与引擎持有的排版")
    func memoryWarningDropsPaginatorLayouts() async throws {
        let paginator = CoreTextPaginator()
        try await withEngine(paginator: paginator) { engine in
            for spine in 0..<4 {
                engine.updateReadingPosition(.chapterStart(spine))
                let outcome = await engine.preloadChapter(at: spine)
                try #require(outcome.isReady)
            }
            try #require(paginator.cachedLayoutCount > 0)
            NotificationCenter.default.post(name: UIApplication.didReceiveMemoryWarningNotification, object: nil)
            #expect(paginator.cachedLayoutCount == 0)
        }
    }

    @Test("尚在文档存储中的相同修订仍命中同一排版")
    func storedDocumentStillHitsTheCache() async throws {
        let paginator = CoreTextPaginator()
        let revision = ContentRevision()
        func layout() async -> CoreTextPaginator.ChapterLayout {
            let text = NSAttributedString(string: Self.chapterText(0), attributes: [.font: UIFont.systemFont(ofSize: 18)])
            return await paginator.paginate(spineIndex: 0, attrStr: text, renderSize: CGSize(width: 390, height: 760),
                                            fontSize: 18, revision: revision)
        }
        let first = await layout()
        let second = await layout()
        #expect(first.framesetter === second.framesetter)
    }

    private func withEngine(paginator: CoreTextPaginator,
                            action: (CoreTextPageEngine) async throws -> Void) async throws {
        let (directory, offsets) = try await Task.detached {
            let directory = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            return (directory, CharOffsetStore(directoryURL: directory))
        }.value
        let engine = CoreTextPageEngine(
            attributedBuilder: MockAttributedStringBuilder(texts: (0..<Self.chapterCount).map(Self.chapterText)),
            renderSettings: EPUBTestFixtures.renderSettings(),
            paginationManager: PaginationManager(paginator: paginator), offsetStore: offsets
        )
        await engine.start(renderSize: CGSize(width: 390, height: 760), bookId: UUID().uuidString)
        let result: Result<Void, Error>
        do { result = .success(try await action(engine)) }
        catch { result = .failure(error) }
        engine.cancelPendingWork(cause: .readerTeardown)
        try await Task.detached {
            offsets.flushSync()
            try FileManager.default.removeItem(at: directory)
        }.value
        try result.get()
    }
}
