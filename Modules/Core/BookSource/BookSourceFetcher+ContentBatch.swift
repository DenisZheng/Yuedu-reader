import Foundation

extension BookSourceFetcher {
    /// 只回存书源明确提供的章节；缺函数／未回存章节由现有单章用例接手。
    /// 注入repository/session用于隔离固定输入，不增加第二份生产缓存或宿主。
    func fetchContentBatch(refs: [OnlineChapterRef], bookId: UUID, source: BookSource,
                           variables: [String: String] = [:],
                           repository: ChapterCacheRepository = BookSourceFetcher.chapterCacheRepository,
                           session supplied: BookSourceSession? = nil) async throws -> [OnlineChapterRef] {
        let candidates = refs.filter { !$0.shouldRenderAsVolumeSeparator }
        guard Set(candidates.map(\.index)).count == candidates.count else { throw SourceContentBatch.Failure.invalidIdentifier }
        guard source.contentBatchSize > 1, candidates.count >= 2 else { return candidates }
        let limited = Array(candidates.prefix(source.contentBatchSize))
        let session = supplied ?? BookSourceSession.session(for: source)
        let batch = SourceContentBatch(refs: limited, bookId: bookId, variables: variables,
            repository: repository, active: { session.isActive })
        defer { batch.close() }
        do {
            try await withTaskCancellationHandler {
                try await session.parse { bridge in
                    try SourcePerfTrace.span("batch.script", "chapters=\(limited.count) main=\(Thread.isMainThread)") {
                        try bridge.runContentBatch(batch)
                    }
                }
                try Task.checkCancellation()
                try batch.checkCurrent()
            } onCancel: { batch.cancel() }
        } catch {
            try batch.checkCurrent()
            if let failure = batch.failure { throw failure }
            throw error
        }
        return batch.missing + candidates.dropFirst(limited.count)
    }
}
