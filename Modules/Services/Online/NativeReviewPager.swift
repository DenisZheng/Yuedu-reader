import Foundation
import Observation

/// 一个段落／回复作用域的原生分页状态；成功才推进，失败保留目标，不持有第二份正文。
@MainActor
@Observable
final class NativeReviewPager {
    private(set) var items: [NativeReviewItem] = []
    private(set) var loading = false
    private(set) var failure: NativeReviewFailure?
    private(set) var hasMore = true
    private(set) var hasSeparateReplies = false
    private(set) var runtimeVariables: [String: String]?
    private(set) var page = 1
    private var nextURL: String?
    private var visited = Set<String>()
    private var generation = 0
    private var buttonTask: Task<Void, Never>?
    private let client: NativeReviewClient
    private let paragraph: NativeReviewSummary.Paragraph
    private let reviewID: String?

    init(client: NativeReviewClient, paragraph: NativeReviewSummary.Paragraph, reviewID: String? = nil,
         runtimeVariables: [String: String]? = nil) {
        self.client = client; self.paragraph = paragraph; self.reviewID = reviewID
        self.runtimeVariables = runtimeVariables
    }

    func cancel() { generation += 1; buttonTask?.cancel(); buttonTask = nil; loading = false }
    func requestNext() {
        guard !loading else { return }
        buttonTask?.cancel()
        buttonTask = Task { await loadNext() }
    }

    private nonisolated static func merge(current: [NativeReviewItem], incoming: [NativeReviewItem]) throws -> (items: [NativeReviewItem], unchanged: Bool) {
        try SourcePerfTrace.span("review.page.merge", "items=\(current.count + incoming.count) main=\(Thread.isMainThread)") {
            var result = current, positions = Dictionary(uniqueKeysWithValues: current.enumerated().map { ($0.element.id, $0.offset) })
            for item in incoming {
                if let index = positions[item.id] { result[index] = item }
                else { positions[item.id] = result.count; result.append(item) }
            }
            guard result.count <= NativeReviewValues.maximumItems else { throw NativeReviewFailure.budget }
            return (result, result == current)
        }
    }

    func loadNext() async {
        guard !loading, hasMore else { return }
        let token = generation
        let target = nextURL
        loading = true; failure = nil
        do {
            let result = try await client.detail(paragraph: paragraph, page: page, nextURL: target, reviewID: reviewID,
                                                 runtimeVariables: runtimeVariables)
            try Task.checkCancellation()
            guard token == generation else { return }
            let snapshot = items
            let joined = try await Task.detached(priority: .userInitiated) {
                try Self.merge(current: snapshot, incoming: result.items)
            }.value
            try Task.checkCancellation()
            guard token == generation else { return }
            let merged = joined.items
            if !client.isJsSource, reviewID == nil, let next = result.nextPageURL {
                guard next != target, !visited.contains(next) else { throw NativeReviewFailure.loop }
            }
            if page > 1, !result.items.isEmpty, joined.unchanged, result.nextPageURL != nil {
                throw NativeReviewFailure.loop
            }
            if let target { visited.insert(target) }
            try client.checkAccess()
            items = merged; page += 1; nextURL = result.nextPageURL
            runtimeVariables = result.runtimeVariables
            hasSeparateReplies = result.hasSeparateReplies
            hasMore = page <= 50 && !result.items.isEmpty && (reviewID == nil ? result.nextPageURL != nil : !joined.unchanged)
            loading = false
        } catch {
            guard token == generation else { return }
            loading = false
            if error is CancellationError { return }
            failure = error as? NativeReviewFailure ?? .response
        }
    }
}
