import Foundation
import os
import Testing
@testable import yuedu_app

/// 使用独立首屏目录、自建源和计数入口验证两条真实首页路径，不运行站点脚本。
@MainActor
@Suite("探索源变量按页读取", .serialized)
struct BookSourceRowEntriesTests {
    private struct Metrics {
        var reads = 0
        var readOnMain = false
        var cpu = 0.0
    }

    private func source() -> BookSource {
        BookSource(bookSourceUrl: "https://row-" + UUID().uuidString.lowercased() + ".invalid", bookSourceName: "隔离列表源")
    }

    private func books(_ count: Int, source: BookSource) -> [OnlineBook] {
        (0..<count).map { index in
            OnlineBook(name: "第\(index)本", author: "作者", intro: "", coverUrl: "", bookUrl: source.bookSourceUrl + "/book/\(index)",
                       tocUrl: "", wordCount: "", lastChapter: "", kind: "", sourceId: source.id, sourceName: "源")
        }
    }

    private func section(_ source: BookSource) -> HomeSection {
        HomeSection(layout: .row, binding: .sourceCategories([
            ExploreCategoryReference(sourceURL: source.bookSourceUrl, title: "分类", url: "/list")
        ]))
    }

    private func store() -> ForYouCandidateStore {
        ForYouCandidateStore(directory: URL.temporaryDirectory.appendingPathComponent("row-entries-" + UUID().uuidString))
    }

    @Test("二十本书只在加载后读取一次变量，且不在主线程解析")
    func readsOnceAfterLoad() async throws {
        let source = source(), page = books(20, source: source)
        let metrics = OSAllocatedUnfairLock(initialState: Metrics())
        let json = try await Task.detached {
            var values: [String: String] = ["发现页类型": "听书"]
            for index in 0..<1500 { values["设置\(index)"] = String(repeating: "合成分类与排序选项", count: 8) }
            return String(decoding: try JSONSerialization.data(withJSONObject: values), as: UTF8.self)
        }.value
        defer { BookSourceRuntimeStateStore.shared.setSourceVariableJSON(nil, for: source.bookSourceUrl) }
        let firstPages = DiscoverFirstPages(
            pageLoader: SectionPageLoader { _, _, _ in
                BookSourceRuntimeStateStore.shared.setSourceVariableJSON(json, for: source.bookSourceUrl)
                return page
            }, primeCookies: { _ in }, store: store(), lanes: DiscoverRequestLanes()
        )
        let provider = BookSourceProvider(source: source, firstPages: firstPages, modeMarkers: { source in
            let start = SourcePerfTrace.threadCPU
            let result = OnlineBookContentInference.sourceRuntimeModeMarkers(for: source)
            let cpu = SourcePerfTrace.threadCPU - start
            metrics.withLock { value in
                value.reads += 1; value.readOnMain = value.readOnMain || Thread.isMainThread; value.cpu += cpu
            }
            return result
        })
        let entries = try await provider.load(section(source))
        let measured = metrics.withLock { $0 }
        print("SOURCE_ROW_METRICS books=20 bytes=\(json.utf8.count) reads=\(measured.reads) main=\(measured.readOnMain) parseCPUms=\(measured.cpu * 1000)")
        #expect(entries.count == 20)
        #expect(measured.reads == 1)
        #expect(!measured.readOnMain)
        #expect(entries.compactMap { if case .item(let record, _, _) = $0 { record.contentKind } else { nil } } == Array(repeating: .audio, count: 20))
    }

    @Test("已保存页面也只读取一次，不发请求或改变条目身份")
    func savedPageReadsOnce() async throws {
        let source = source(), page = books(4, source: source), store = store()
        let reads = OSAllocatedUnfairLock(initialState: 0)
        let requests = OSAllocatedUnfairLock(initialState: 0)
        await store.write(ForYouCandidates(sourceURL: source.bookSourceUrl, categoryURL: "/list", fetchedAt: Date(), books: page))
        let firstPages = DiscoverFirstPages(pageLoader: SectionPageLoader { _, _, _ in
            requests.withLock { $0 += 1 }; return []
        }, primeCookies: { _ in }, store: store, lanes: DiscoverRequestLanes())
        let provider = BookSourceProvider(source: source, firstPages: firstPages, modeMarkers: { _ in
            reads.withLock { $0 += 1 }; return []
        })
        let entries = try #require(await provider.savedPage(section(source)))
        #expect(reads.withLock { $0 } == 1)
        #expect(requests.withLock { $0 } == 0)
        #expect(entries == page.map { CollectionEntry.onlineBook($0, source: source) })
    }

    @Test("主脚本书籍位标记仍优先，不被同源听书标记覆盖")
    func mainJsFlagsWin() {
        var source = source()
        source.mainJs = "function getContent() { return ''; }"
        var book = books(1, source: source)[0]
        for (flag, kind) in [(4, OnlineBookContentKind.video), (8, .text), (32, .audio), (64, .manga), (128, .file)] {
            book.runtimeVariables = ["book.type": String(flag)]
            #expect(book.inferredContentKind(source: source, sourceModeMarkers: ["听书"]) == kind)
        }
    }

    @Test("空页面不读取变量且保持合法空结果")
    func emptyPageDoesNotReadVariables() async throws {
        let source = source(), reads = OSAllocatedUnfairLock(initialState: 0)
        let firstPages = DiscoverFirstPages(pageLoader: SectionPageLoader { _, _, _ in [] }, primeCookies: { _ in }, store: store(), lanes: DiscoverRequestLanes())
        let provider = BookSourceProvider(source: source, firstPages: firstPages, modeMarkers: { _ in
            reads.withLock { $0 += 1 }; return []
        })
        #expect(try await provider.load(section(source)).isEmpty)
        #expect(reads.withLock { $0 } == 0)
        #expect(await provider.savedPage(section(source)) == nil)
    }
}
