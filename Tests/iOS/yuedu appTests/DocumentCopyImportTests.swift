import Foundation
import Testing
import UIKit
import UniformTypeIdentifiers
import os
@testable import yuedu_app

@Suite("JSON复制导入与选择器交付", .serialized)
struct DocumentCopyImportTests {
    @Test("实际原生选择器使用复制导入而不是原地打开")
    @MainActor func usesImportMode() {
        let picker = DocumentCopyPicker.makePicker(contentTypes: [.json, .data])
        #expect(picker.documentPickerMode == .import)
        #expect(!picker.allowsMultipleSelection)
        // 扩展名显示由系统Files服务决定，不用未呈现时的getter判断交付模式。
    }

    @Test("先选中或先关闭都只在两个事件齐全后交付一次")
    @MainActor func deliveryOrder() throws {
        let url = URL(fileURLWithPath: "/unused-fixture.json")
        for dismissFirst in [true, false] {
            let handoff = DocumentCopyImportHandoff()
            let file = ImportedDocumentCopy(url: url, startAccess: { _ in false })
            if dismissFirst {
                #expect(handoff.dismissed() == nil)
                let result = try #require(handoff.selected(.success(file), id: handoff.id))
                #expect(try result.get().url == url)
            } else {
                #expect(handoff.selected(.success(file), id: handoff.id) == nil)
                let result = try #require(handoff.dismissed())
                #expect(try result.get().url == url)
            }
            #expect(handoff.dismissed() == nil)
            #expect(handoff.selected(.success(file), id: handoff.id) == nil)
        }
    }

    @Test("取消不交付，旧轮回调不能关闭或复活新一轮结果")
    @MainActor func cancellationAndOldResults() {
        let handoff = DocumentCopyImportHandoff()
        let oldID = handoff.id
        handoff.cancel(id: oldID)
        let file = ImportedDocumentCopy(url: URL(fileURLWithPath: "/unused.json"), startAccess: { _ in false })
        #expect(handoff.selected(.success(file), id: oldID) == nil)
        #expect(handoff.dismissed() == nil)
        handoff.begin()
        #expect(handoff.selected(.success(file), id: oldID) == nil)
        handoff.cancel(id: oldID)
        #expect(handoff.selected(.success(file), id: handoff.id) == nil)
        #expect(handoff.dismissed() != nil)
    }

    @Test("权限在交付和异步读取期间保留，释放时只平衡成功的start")
    @MainActor func scopeLifetime() {
        let stops = OSAllocatedUnfairLock(initialState: 0)
        let handoff = DocumentCopyImportHandoff()
        var file: ImportedDocumentCopy? = ImportedDocumentCopy(url: URL(fileURLWithPath: "/unused.json"),
            startAccess: { _ in true }, stopAccess: { _ in stops.withLock { $0 += 1 } })
        weak var weakFile = file
        _ = handoff.selected(.success(file!), id: handoff.id)
        file = nil
        #expect(weakFile != nil && stops.withLock { $0 } == 0)
        var delivered = handoff.dismissed()
        #expect(delivered != nil && stops.withLock { $0 } == 0)
        delivered = nil
        #expect(weakFile == nil && stops.withLock { $0 } == 1)
        var noScope: ImportedDocumentCopy? = ImportedDocumentCopy(url: URL(fileURLWithPath: "/unused.json"),
            startAccess: { _ in false }, stopAccess: { _ in stops.withLock { $0 += 1 } })
        #expect(noScope != nil)
        noScope = nil
        #expect(stops.withLock { $0 } == 1)
    }

    @Test("协调读取沙盒副本保留字节、拒绝超限并正常报告文件不存在")
    func coordinatedReads() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { do { try FileManager.default.removeItem(at: directory) } catch { Issue.record(error) } }
        let url = directory.appendingPathComponent("fixture.json")
        let data = Data("{\"fixture\":true}".utf8)
        try data.write(to: url)
        #expect(try DocumentImportReader.read(url, maximumBytes: data.count) == data)
        #expect(throws: DocumentImportReader.Failure.self) {
            try DocumentImportReader.read(url, maximumBytes: data.count - 1)
        }
        #expect(throws: (any Error).self) {
            try DocumentImportReader.read(directory.appendingPathComponent("missing.json"), maximumBytes: 100)
        }
    }

    @Test("书源系统副本后台解析后仍只进入确认页，不自动保存")
    @MainActor func bookSourceCopyKeepsReviewBoundary() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { do { try FileManager.default.removeItem(at: directory) } catch { Issue.record(error) } }
        let store = BookSourceStore(directory: directory.appendingPathComponent("store"))
        await store.waitUntilLoaded()
        let url = directory.appendingPathComponent("book-source.json")
        try Data(#"[{"bookSourceUrl":"https://fixture.invalid","bookSourceName":"测试源"}]"#.utf8).write(to: url)
        let flow = BookSourceAddFlow(store: store)
        flow.handleImportFile(.success(ImportedDocumentCopy(url: url)))
        await flow.waitForFileImport()
        #expect(flow.message == nil)
        #expect(!flow.fileImportLoading)
        #expect(flow.importCoordinator.pending != nil)
        #expect(store.sources.isEmpty)
        flow.importCoordinator.cancel()
        flow.handleImportFile(.success(ImportedDocumentCopy(url: url)))
        flow.cancelImport()
        await flow.waitForFileImport()
        #expect(flow.importCoordinator.pending == nil)
        #expect(!flow.fileImportLoading && store.sources.isEmpty)
    }

    @Test("RSS确认请求保留系统副本，继续使用原配置加载和比较流程")
    @MainActor func rssCopyKeepsExistingParser() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { do { try FileManager.default.removeItem(at: directory) } catch { Issue.record(error) } }
        let url = directory.appendingPathComponent("rss.json")
        try Data(#"[{"sourceUrl":"https://fixture.invalid/rss","sourceName":"测试订阅"}]"#.utf8).write(to: url)
        let request = RSSImportReviewRequest(input: .file(url), copiedFile: ImportedDocumentCopy(url: url))
        let loaded = try await RSSImportService.load(request.input)
        #expect(request.copiedFile != nil)
        #expect(loaded.candidates.first?.source?.sourceKey == "https://fixture.invalid/rss")
        #expect(loaded.requests == 0)
    }
}
