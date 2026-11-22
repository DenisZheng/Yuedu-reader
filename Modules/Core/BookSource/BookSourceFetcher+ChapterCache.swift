import Foundation

// MARK: - Chapter Cache Delegation (ChapterCacheRepository)

extension BookSourceFetcher {

    nonisolated func loadNormalizedChapterHTMLSync(
        bookId: UUID,
        chapterIndex: Int,
        expectedSourceURL: String? = nil,
        expectedTOCTitle: String? = nil
    ) -> String? {
        Self.chapterCacheRepository.loadNormalizedChapterHTMLSync(
            bookId: bookId,
            chapterIndex: chapterIndex,
            expectedSourceURL: expectedSourceURL,
            expectedTOCTitle: expectedTOCTitle
        )
    }

    nonisolated func isChapterCached(
        bookId: UUID,
        chapterIndex: Int,
        expectedSourceURL: String? = nil,
        expectedTOCTitle: String? = nil
    ) -> Bool {
        Self.chapterCacheRepository.isChapterCached(
            bookId: bookId,
            chapterIndex: chapterIndex,
            expectedSourceURL: expectedSourceURL,
            expectedTOCTitle: expectedTOCTitle
        )
    }

    nonisolated func cachedChapterIndices(bookId: UUID, refs: [OnlineChapterRef]) -> Set<Int> {
        Self.chapterCacheRepository.cachedChapterIndices(bookId: bookId, refs: refs)
    }

    nonisolated func clearChapterCache(bookId: UUID, chapterIndex: Int) {
        Self.chapterCacheRepository.clearChapterCache(bookId: bookId, chapterIndex: chapterIndex)
    }

    /// Clear all chapter caches for a book (called when switching sources)
    nonisolated func clearAllChapterCache(bookId: UUID) {
        Self.chapterCacheRepository.clearAllChapterCache(bookId: bookId)
    }

    nonisolated func clearChapterCacheAsync(bookId: UUID, chapterIndex: Int) async throws {
        try await Self.chapterCacheRepository.clearChapterCacheAsync(bookId: bookId, chapterIndex: chapterIndex)
    }

    nonisolated func clearAllChapterCacheAsync(bookId: UUID) async throws {
        try await Self.chapterCacheRepository.clearAllChapterCacheAsync(bookId: bookId)
    }

    @discardableResult
    nonisolated func saveToCache(
        content: String,
        bookId: UUID,
        chapterIndex: Int,
        sourceURL: String? = nil,
        tocTitle: String? = nil,
        extractedTitle: String? = nil,
        rawHTML: String? = nil,
        storeNormalizedHTML: Bool = true
    ) throws -> String {
        try Self.chapterCacheRepository.saveToCache(
            content: content,
            bookId: bookId,
            chapterIndex: chapterIndex,
            sourceURL: sourceURL,
            tocTitle: tocTitle,
            extractedTitle: extractedTitle,
            rawHTML: rawHTML,
            storeNormalizedHTML: storeNormalizedHTML
        )
    }

    @discardableResult
    nonisolated func saveChapterPackageToCache(
        _ package: ChapterPackage,
        rawHTML: String?,
        normalizedHTML: String?,
        writeTicket: ChapterCacheRepository.WriteTicket? = nil
    ) throws -> String {
        try Self.chapterCacheRepository.saveChapterPackageToCache(
            package,
            rawHTML: rawHTML,
            normalizedHTML: normalizedHTML,
            writeTicket: writeTicket
        )
    }

    nonisolated func loadCachedChapterMetadataSync(bookId: UUID, chapterIndex: Int) -> CachedChapterMetadata? {
        Self.chapterCacheRepository.loadCachedChapterMetadataSync(
            bookId: bookId,
            chapterIndex: chapterIndex
        )
    }

    nonisolated func loadChapterPackageSync(
        bookId: UUID,
        chapterIndex: Int,
        expectedSourceURL: String? = nil,
        expectedTOCTitle: String? = nil
    ) -> ChapterPackage? {
        Self.chapterCacheRepository.loadChapterPackageSync(
            bookId: bookId,
            chapterIndex: chapterIndex,
            expectedSourceURL: expectedSourceURL,
            expectedTOCTitle: expectedTOCTitle
        )
    }
}

extension BookSourceFetching {
    /// 同步实现也不能借调用者的 MainActor 做 I/O；生产实现另在取得书锁后检查取消。
    @concurrent
    func clearChapterCacheAsync(bookId: UUID, chapterIndex: Int) async throws {
        try Task.checkCancellation()
        clearChapterCache(bookId: bookId, chapterIndex: chapterIndex)
    }
}
