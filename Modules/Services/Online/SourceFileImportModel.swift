import Foundation
import Observation

@MainActor @Observable
final class SourceFileImportModel {
    enum Phase { case loading, ready, importing, imported, failed }
    private(set) var phase: Phase = .loading
    private(set) var book: OnlineBook
    private(set) var message: String?
    private(set) var importedBookID: UUID?
    @ObservationIgnored private var source: BookSource?
    @ObservationIgnored private var work: Task<Void, Never>?
    @ObservationIgnored private var generation: UInt64 = 0

    init(book: OnlineBook) { self.book = book }

    func load(fetcher: any BookSourceFetching, sources: BookSourceStore) async {
        cancel()
        let ticket = generation
        phase = .loading; message = nil
        let task = Task { await performLoad(fetcher: fetcher, sources: sources, ticket: ticket) }
        work = task
        await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
        if generation == ticket { work = nil }
    }

    private func performLoad(fetcher: any BookSourceFetching, sources: BookSourceStore, ticket: UInt64) async {
        await sources.waitUntilLoaded()
        guard generation == ticket, !Task.isCancelled else { return }
        guard let source = sources.source(id: book.sourceId) else {
            message = SourceFileImportService.Failure.sourceUnavailable.localizedDescription
            phase = .failed
            return
        }
        let revision = sources.mutationRevision
        do {
            let result = try await SourceFileImportService.load(book: book, source: source, fetcher: fetcher)
            try Task.checkCancellation()
            guard generation == ticket else { return }
            guard sources.mutationRevision == revision else { throw SourceFileImportService.Failure.staleConfiguration }
            self.source = source; book = result; phase = .ready
        } catch is CancellationError {
            if generation == ticket { phase = .failed; message = localized("載入已取消") }
        } catch { if generation == ticket { fail(error) } }
    }

    func startImport(_ rawURL: String, sources: BookSourceStore, store: BookStore) {
        guard phase == .ready, let source else { return }
        cancel()
        let ticket = generation
        phase = .importing; message = nil
        let book = book
        work = Task {
            do {
                let imported = try await SourceFileImportService.importFile(rawURL: rawURL, book: book,
                    source: source, sources: sources, store: store)
                guard generation == ticket else { return }
                importedBookID = imported.id; phase = .imported
            } catch is CancellationError {
                if generation == ticket { phase = .ready; message = localized("下載已取消") }
            } catch { if generation == ticket { phase = .ready; message = Self.message(for: error) } }
        }
    }

    func cancel() {
        generation &+= 1
        work?.cancel()
        if phase == .loading { phase = .failed; message = localized("載入已取消") }
        else if phase == .importing { phase = .ready; message = localized("下載已取消") }
    }
    func waitForWork() async { await work?.value }
    private func fail(_ error: Error) { phase = .failed; message = Self.message(for: error) }
    private static func message(for error: Error) -> String {
        // 源异常可能携带请求和脚本内容，界面只显示已定义错误或安全通用提示。
        (error as? SourceFileImportService.Failure)?.localizedDescription ?? localized("檔案載入失敗，請重試")
    }
}
