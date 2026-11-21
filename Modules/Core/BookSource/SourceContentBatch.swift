import Foundation
import JavaScriptCore
import os

/// 一次批量脚本的回调上下文；只登记这批身份和结果，正文仍交给ChapterCacheRepository。
final class SourceContentBatch: @unchecked Sendable {
    enum Failure: LocalizedError {
        case invalidIdentifier, budget, javascript, missingRule
        var errorDescription: String? {
            switch self {
            case .invalidIdentifier: return localized("批量正文未唯一匹配本批章節；同URL請傳章節物件。")
            case .budget: return localized("批量正文超過本批16 MiB預算。")
            case .javascript: return localized("批量正文腳本失敗，未完成章節將改用單章下載。")
            case .missingRule: return localized("書源未配置有效的批量正文規則。")
            }
        }
    }
    let refs: [OnlineChapterRef]
    let variables: [String: String]
    private let bookId: UUID
    private let repository: ChapterCacheRepository
    private let active: @Sendable () -> Bool
    private let cancellation = OSAllocatedUnfairLock(initialState: false)
    private let tickets: [Int: ChapterCacheRepository.WriteTicket]
    private struct State { var saved = Set<Int>(); var closed = false; var bytes = 0; var failure: (any Error)? }
    private let state = OSAllocatedUnfairLock(initialState: State())
    var failure: (any Error)? { state.withLock { $0.failure } }

    init(refs: [OnlineChapterRef], bookId: UUID, variables: [String: String],
         repository: ChapterCacheRepository, active: @escaping @Sendable () -> Bool) {
        self.refs = refs; self.bookId = bookId; self.variables = variables
        self.repository = repository; self.active = active
        self.tickets = Dictionary(uniqueKeysWithValues: refs.map { ($0.index, repository.beginWrite(bookId: bookId, chapterIndex: $0.index)) })
    }
    func cancel() { cancellation.withLock { $0 = true } }
    func close() {
        state.withLock { $0.closed = true }
        for ticket in tickets.values { repository.finishWrite(ticket) }
    }
    func checkCurrent() throws {
        guard !cancellation.withLock({ $0 }), active() else { throw CancellationError() }
    }
    var missing: [OnlineChapterRef] { state.withLock { state in refs.filter { !state.saved.contains($0.index) } } }

    /// index是身份，URL只作无歧义的兼容标识；不把循环下标或已完成状态当作消歧。
    private func resolve(_ value: JSValue) throws -> OnlineChapterRef {
        if value.isObject, let index = value.forProperty("index"), index.isNumber {
            let number = index.toDouble()
            guard number.isFinite, number.rounded() == number,
                  let ref = refs.first(where: { Double($0.index) == number }) else { throw Failure.invalidIdentifier }
            return ref
        }
        if value.isString, let url = value.toString()?.trimmingCharacters(in: .whitespacesAndNewlines), !url.isEmpty {
            let base = variables["book.tocUrl"] ?? variables["book.bookUrl"] ?? ""
            let absolute = URL(string: url, relativeTo: URL(string: base))?.absoluteURL.absoluteString ?? url
            let candidates = refs.filter { ref in
                let normalized = URL(string: ref.url, relativeTo: URL(string: base))?.absoluteURL.absoluteString ?? ref.url
                return ref.url == url || normalized == absolute
            }
            if candidates.count == 1 { return candidates[0] }
        }
        throw Failure.invalidIdentifier
    }

    func save(_ identifier: JSValue, content: String,
              replace: (OnlineChapterRef, String) throws -> String) throws -> Bool {
        try checkCurrent()
        guard !state.withLock({ $0.closed }) else { return false }
        let ref = try resolve(identifier)
        let text = try replace(ref, content)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        try state.withLock { state in
            state.bytes += text.utf8.count
            guard state.bytes <= 16 * 1024 * 1024 else { throw Failure.budget }
        }
        try checkCurrent()
        guard let ticket = tickets[ref.index] else { throw Failure.invalidIdentifier }
        _ = try SourcePerfTrace.span("batch.cache", "index=\(ref.index) bytes=\(text.utf8.count) main=\(Thread.isMainThread)") {
            try repository.saveToCache(content: text, bookId: bookId, chapterIndex: ref.index,
                sourceURL: ref.url, tocTitle: ref.title, rawHTML: text, writeTicket: ticket)
        }
        _ = state.withLock { $0.saved.insert(ref.index) }
        return true
    }
    func record(_ error: any Error) { state.withLock { $0.failure = error } }
}

extension BookSource {
    var contentBatchSize: Int {
        guard let size = ruleContent.maxBatchSize, size > 1,
              isJsSource || !ruleContent.contentBatch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return 1 }
        return min(size, 50)
    }
}
