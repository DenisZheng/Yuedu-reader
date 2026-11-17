import Foundation
import Testing
import UIKit
@testable import yuedu_app

/// 改编自上游66124f63／97b4f5b7：真实HTML管线下的长章CPU与取消回归。
/// 固定输入不含相邻CJK标点，以隔离整章字符串重复桥接，而非CoreText自身的标点排版成本。
@Suite("CoreText长章节分页", .serialized)
struct CoreTextLongChapterPaginationTests {
    private static let renderSize = CGSize(width: 390, height: 844)

    @Test("四倍长度的长章分页成本保持线性量级")
    @MainActor
    func longChapterPaginationIsLinear() async {
        _ = await layout(characterCount: 5_000)
        let short = await layout(characterCount: 100_000)
        let long = await layout(characterCount: 400_000)
        let ratio = long.milliseconds / max(short.milliseconds, 1)
        print("longChapter short=\(short.characters)ch \(Int(short.milliseconds))ms pages=\(short.pages) long=\(long.characters)ch \(Int(long.milliseconds))ms pages=\(long.pages) ratio=\(String(format: "%.2f", ratio))")
        let event = await layout(characterCount: 857_793)
        print("longChapter event=\(event.characters)ch \(Int(event.milliseconds))ms pages=\(event.pages)")
        #expect(long.pages > short.pages * 3)
        #expect(ratio < 6, "四倍正文耗时\(String(format: "%.1f", ratio))倍")
    }

    @Test("取消调用方会停止完整分页，残缺结果不污染缓存")
    @MainActor
    func cancelledPaginationStopsAndIsNotCached() async {
        let attributedString = await Self.chapter(characterCount: 400_000)
        let paginator = CoreTextPaginator()
        let revision = ContentRevision()
        let shared = LayoutShared(attributedString)
        let cancelled = Task { @MainActor in
            await paginator.paginate(spineIndex: 0, attrStr: shared.wrappedValue,
                                     renderSize: Self.renderSize, fontSize: 17, revision: revision)
        }
        cancelled.cancel()
        let stopped = await cancelled.value
        #expect(stopped.isPartial)
        let full = await paginator.paginate(spineIndex: 0, attrStr: attributedString,
                                            renderSize: Self.renderSize, fontSize: 17, revision: revision)
        #expect(!full.isPartial)
        #expect(full.pageRanges.count > stopped.pageRanges.count)
        #expect(full.pageRanges.last.map { $0.location + $0.length } == attributedString.length)
    }

    @Test("两阶段打开的首屏计算同样响应调用方取消")
    @MainActor
    func cancelledFirstPageStops() async throws {
        let attributedString = await Self.chapter(characterCount: 100_000)
        let paginator = CoreTextPaginator()
        let shared = LayoutShared(attributedString)
        let cancelled = Task { @MainActor in
            await paginator.paginateFirstPage(spineIndex: 0, attrStr: shared.wrappedValue,
                                              renderSize: Self.renderSize, fontSize: 17, revision: ContentRevision())
        }
        cancelled.cancel()
        let stopped = try #require(await cancelled.value)
        #expect(stopped.isPartial)
        #expect(stopped.pageRanges.isEmpty)
    }

    @MainActor
    private func layout(characterCount: Int) async -> (milliseconds: Double, pages: Int, characters: Int) {
        let attributedString = await Self.chapter(characterCount: characterCount)
        let paginator = CoreTextPaginator()
        let start = ProcessInfo.processInfo.systemUptime
        let result = await paginator.paginate(spineIndex: 0, attrStr: attributedString,
                                              renderSize: Self.renderSize, fontSize: 17, revision: ContentRevision())
        return ((ProcessInfo.processInfo.systemUptime - start) * 1000, result.pageRanges.count, attributedString.length)
    }

    private static func chapter(characterCount: Int) async -> NSAttributedString {
        let paragraph = "他抬起頭看見城牆上的旗幟在風中翻捲他知道這一戰他們必須贏下來眾人沉默片刻後隨即齊聲應和。"
        let paragraphCount = max(1, characterCount / (paragraph.utf16.count + 1))
        let body = String(repeating: "<p>\(paragraph)</p>", count: paragraphCount)
        return await EPUBTestFixtures.renderIR(
            html: EPUBTestFixtures.xhtml(title: "long", body: body),
            config: EPUBTestFixtures.htmlConfig(renderWidth: renderSize.width)
        )
    }
}
