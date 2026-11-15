import Combine
import Foundation

/// 系统与站内链接共用的源包导入状态机；先限额下载并分类，再进入对应业务的确认页。
/// 预览前不写库、不执行源脚本；取消和新请求使晚到结果失效。
@MainActor
final class BookSourceDeepLinkHandler: ObservableObject {
    enum Phase: Equatable {
        case idle
        case confirming(sourceURL: URL)
        case importing
        case reviewing
        case reviewingRSS(RSSImportReviewRequest)
        case succeeded(count: Int)
        case failed(message: String)
    }

    @Published private(set) var phase: Phase = .idle
    let coordinator: BookSourceImportCoordinator
    let rssStore: RSSStore
    private let bookStore: BookSourceStore
    private let fetch: RSSImportService.Fetch?
    private var work: Task<Void, Never>?
    private var generation = 0

    init(bookStore: BookSourceStore = .shared, rssStore: RSSStore = .shared,
         fetch: RSSImportService.Fetch? = nil) {
        self.bookStore = bookStore
        self.rssStore = rssStore
        self.fetch = fetch
        self.coordinator = BookSourceImportCoordinator(store: bookStore)
    }

    func handle(url: URL) {
        if case .importing = phase { return }
        guard let sourceURL = BookSourceImportDeepLink.sourceURL(from: url), RSSImportService.validURL(sourceURL) else { return }
        cancel()
        phase = .confirming(sourceURL: sourceURL)
    }

    func confirm() {
        guard case .confirming(let sourceURL) = phase else { return }
        generation &+= 1
        let revision = generation
        phase = .importing
        work = Task {
            defer { if revision == generation { work = nil } }
            do {
                let loaded = try await Self.read(sourceURL, bookStore: bookStore, fetch: fetch)
                try Task.checkCancellation()
                guard revision == generation else { return }
                switch loaded {
                case .books(let sources):
                    coordinator.present(sources: sources)
                    phase = .reviewing
                case .rss(let sources):
                    phase = .reviewingRSS(.init(input: .prepared(sources)))
                }
            } catch is CancellationError {
                if revision == generation { phase = .idle }
            } catch {
                guard revision == generation, !Task.isCancelled else { return }
                phase = .failed(message: (error as? RSSImportService.Issue)?.message
                    ?? DiagnosticRedactor.redact(error.localizedDescription))
            }
        }
    }

    func waitForWork() async { await work?.value }

    func cancel() {
        generation &+= 1
        work?.cancel()
        coordinator.cancel()
        phase = .idle
    }

    func commitReview() {
        guard case .reviewing = phase else { return }
        do { phase = .succeeded(count: try coordinator.confirmImport()) }
        catch { phase = .failed(message: DiagnosticRedactor.redact(error.localizedDescription)) }
    }

    func finish() { cancel() }

    private enum Loaded: Sendable { case books([BookSource]), rss(RSSImportService.Loaded) }

    @concurrent private static func read(_ url: URL, bookStore: BookSourceStore,
                                        fetch: RSSImportService.Fetch?) async throws -> Loaded {
        try Task.checkCancellation()
        let maximumBytes = RSSImportService.Limits().bytesPerDocument
        let data: Data
        if let fetch { data = try await fetch(url, maximumBytes) }
        else { data = try await RSSImportService.download(url, maximumBytes: maximumBytes) }
        try Task.checkCancellation()
        guard data.count <= maximumBytes else { throw RSSImportService.Issue.responseTooLarge }
        guard !data.isEmpty else { throw BookSourceStore.ImportError.invalidData }
        let ext = url.pathExtension.isEmpty ? "json" : url.pathExtension
        switch try await SharedImportPayloadClassifier.classifyOffMain(data: data, fileExtension: ext, suggestedFilename: url.lastPathComponent) {
        case .rssLegadoJSON:
            return .rss(try await RSSImportService.load(.data(data), fetch: fetch))
        case .bookSource(let format):
            return .books(try bookStore.parseForImport(data: data, fileExtension: format))
        default:
            throw BookSourceStore.ImportError.invalidData
        }
    }
}
