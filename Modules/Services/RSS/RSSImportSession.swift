import Foundation
import Observation

/// 确认、保存与首次刷新为三个状态；取消预览不写盘，取消刷新不撤回已保存配置。
@MainActor @Observable
final class RSSImportSession {
    enum Phase { case loading, review, saving, saved, saveFailed, failed }
    private(set) var phase: Phase = .loading
    private(set) var plan: RSSImportService.Plan?
    var selected: Set<UUID> = []
    private(set) var message: String?
    private(set) var isRefreshing = false
    private(set) var refreshMessage: String?
    @ObservationIgnored private let store: RSSStore
    @ObservationIgnored private var loaded: RSSImportService.Loaded?
    @ObservationIgnored private var changes: RSSImportService.Changes?
    @ObservationIgnored private var work: Task<Void, Never>?
    @ObservationIgnored private var cancelled = false

    init(store: RSSStore) { self.store = store }

    func load(_ input: RSSImportService.Input) async {
        do {
            let loaded = try await RSSImportService.load(input)
            try Task.checkCancellation()
            await compare(loaded)
        } catch is CancellationError { cancelled = true }
        catch { fail((error as? RSSImportService.Issue) ?? .invalidFormat) }
    }

    func compare(_ loaded: RSSImportService.Loaded) async {
        phase = .loading
        do {
            let plan = try await RSSImportService.compare(loaded, with: store.importSnapshot())
            try Task.checkCancellation()
            guard !cancelled else { return }
            self.loaded = loaded
            self.plan = plan
            self.selected = plan.initialSelection
            message = nil
            phase = .review
        } catch is CancellationError { cancelled = true }
        catch { fail((error as? RSSImportService.Issue) ?? .invalidFormat) }
    }

    func recompare() {
        guard let loaded else { return }
        work?.cancel()
        work = Task { await compare(loaded) }
    }

    func confirm() {
        guard phase == .review, let plan, !selected.isEmpty else { return }
        let selection = selected
        phase = .saving
        work = Task {
            do {
                let changes = try await RSSImportService.changes(for: plan, selected: selection)
                self.changes = changes
                try await store.commitImport(changes)
                guard !cancelled else { return }
                message = String(format: localized("已儲存：新增 %d、更新 %d、跳過 %d、錯誤 %d"),
                                 changes.added, changes.updated, changes.skipped, changes.errors)
                phase = .saved
            } catch is CancellationError { cancelled = true }
            catch {
                guard !cancelled else { return }
                let issue = (error as? RSSImportService.Issue) ?? .persistence
                message = issue.message
                phase = issue == .persistence ? .saveFailed : .review
            }
        }
    }

    func retrySave() {
        guard phase == .saveFailed else { return }
        phase = .saving
        work = Task {
            do {
                try await store.retryPersistence()
                guard !cancelled else { return }
                message = localized("目前的本地訂閱更改已儲存")
                phase = .saved
            } catch {
                guard !cancelled else { return }
                message = RSSImportService.Issue.persistence.message
                phase = .saveFailed
            }
        }
    }

    func refresh(makeFetcher: @escaping @MainActor () -> RSSFetcher = { RSSFetcher() }) {
        guard phase == .saved, !isRefreshing, let changes else { return }
        isRefreshing = true
        refreshMessage = nil
        work = Task {
            var count = 0
            let succeeded = await RSSFeedRefreshService.refreshAll(store: store, sourceIDs: changes.changedIDs,
                makeFetcher: makeFetcher, onProgress: { _, total in count = total })
            isRefreshing = false
            guard !cancelled else { return }
            if Task.isCancelled { refreshMessage = localized("刷新已取消，已儲存的配置不受影響") }
            else if count == 0 { refreshMessage = localized("此批次沒有可刷新的列表源") }
            else { refreshMessage = succeeded ? localized("首次刷新完成") : localized("配置已儲存，但首次刷新失敗，可稍後重試") }
        }
    }

    func cancelRefresh() { work?.cancel() }
    func cancel() { cancelled = true; work?.cancel() }

    /// 确定性的异步边界，用于测试确认/取消，不以sleep猜测状态。
    func waitForWork() async { await work?.value }

    private func fail(_ issue: RSSImportService.Issue) {
        guard !cancelled else { return }
        message = issue.message
        phase = .failed
    }
}
