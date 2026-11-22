import SwiftUI

struct NativeReviewSelection: Identifiable, Sendable {
    let book: ReadingBook
    let source: BookSource
    let chapter: OnlineChapterRef
    var id: String { book.id.uuidString + ":" + String(chapter.index) }
}

/// 只读原生段评入口，保留旧网页段评；标题/-1与正文段落号使用源协议，不猜测CoreText页码。
struct NativeReviewView: View {
    let selection: NativeReviewSelection
    @Environment(\.dismiss) private var dismiss
    @State private var client: NativeReviewClient?
    @State private var summary: NativeReviewSummary?
    @State private var failure: NativeReviewFailure?
    @State private var loading = true
    @State private var buttonTask: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            Group {
                if loading { ProgressView().accessibilityLabel(localized("載入中")) }
                else if let failure {
                    ContentUnavailableView {
                        Label(localized("段評無法載入"), systemImage: "exclamationmark.bubble")
                    } description: { Text(failure.localizedDescription) }
                    actions: { Button(localized("重試")) { buttonTask?.cancel(); buttonTask = Task { await load() } } }
                } else if let summary, !summary.paragraphs.isEmpty {
                    List(summary.paragraphs) { paragraph in
                        NavigationLink(value: paragraph) {
                            HStack {
                                Text(paragraph.index == -1 ? localized("本章說") : String(format: localized("第%d段"), paragraph.index))
                                Spacer()
                                Text(String(paragraph.count)).foregroundStyle(DSColor.textSecondary)
                            }
                        }
                    }
                } else { ContentUnavailableView(localized("此章沒有原生段評"), systemImage: "text.bubble") }
            }
            .navigationTitle(localized("原生段評"))
            .toolbarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: { Image(systemName: "xmark").accessibilityHidden(true) }.accessibilityLabel(localized("關閉"))
                }
            }
            .navigationDestination(for: NativeReviewSummary.Paragraph.self) { paragraph in
                if let client, let summary {
                    NativeReviewPageView(client: client, paragraph: paragraph, runtimeVariables: summary.runtimeVariables)
                }
            }
        }
        .task(id: selection.id) { await load() }
        .onDisappear { buttonTask?.cancel(); buttonTask = nil }
    }
    private func load() async {
        loading = true; failure = nil
        do {
            let snapshot = selection
            let worker: NativeReviewClient
            if let client { worker = client }
            else {
                worker = await Task.detached(priority: .userInitiated) {
                    NativeReviewClient(source: snapshot.source, book: snapshot.book, chapter: snapshot.chapter)
                }.value
                client = worker
            }
            let value = try await worker.summary()
            try worker.checkAccess(); summary = value; loading = false
        } catch is CancellationError {
            guard !Task.isCancelled else { return }; loading = false; failure = .unavailable
        }
        catch { guard !Task.isCancelled else { return }; failure = error as? NativeReviewFailure ?? .response; loading = false }
    }
}

private struct NativeReviewReplyRoute: Hashable { let id: String }

struct NativeReviewPageView: View {
    let client: NativeReviewClient
    let paragraph: NativeReviewSummary.Paragraph
    let reviewID: String?
    @State private var pager: NativeReviewPager

    init(client: NativeReviewClient, paragraph: NativeReviewSummary.Paragraph, reviewID: String? = nil,
         runtimeVariables: [String: String]? = nil) {
        self.client = client; self.paragraph = paragraph; self.reviewID = reviewID
        _pager = State(initialValue: NativeReviewPager(client: client, paragraph: paragraph, reviewID: reviewID,
                                                       runtimeVariables: runtimeVariables))
    }

    var body: some View {
        List {
            ForEach(pager.items) { item in
                Section {
                    reviewRow(item)
                    if reviewID == nil {
                        ForEach(item.replies) { reply in reviewRow(reply) }
                        if let id = item.sourceID, pager.hasSeparateReplies {
                            NavigationLink(localized("查看回覆"), value: NativeReviewReplyRoute(id: id))
                        }
                    }
                }
            }
            if pager.loading { ProgressView().accessibilityLabel(localized("載入中")) }
            if let failure = pager.failure {
                Section {
                    Text(failure.localizedDescription).foregroundStyle(DSColor.textSecondary)
                    Button(localized("重試")) { pager.requestNext() }
                }
            } else if pager.hasMore {
                Button(localized("載入更多")) { pager.requestNext() }
            } else if pager.items.isEmpty {
                ContentUnavailableView(localized("沒有段評或回覆"), systemImage: "text.bubble")
            }
        }
        .navigationTitle(reviewID == nil ? localized("段評詳情") : localized("段評回覆"))
        .toolbarTitleDisplayMode(.inline)
        .navigationDestination(for: NativeReviewReplyRoute.self) { reply in
            NativeReviewPageView(client: client, paragraph: paragraph, reviewID: reply.id, runtimeVariables: pager.runtimeVariables)
        }
        .task { if pager.items.isEmpty { await pager.loadNext() } }
        .onDisappear { pager.cancel() }
    }

    private func reviewRow(_ item: NativeReviewItem) -> some View {
        VStack(alignment: .leading, spacing: DSSpacing.sm) {
            if !item.name.isEmpty || item.time != nil {
                ViewThatFits(in: .horizontal) {
                    HStack { reviewByline(item) }
                    VStack(alignment: .leading, spacing: DSSpacing.xs) { reviewByline(item) }
                }
            }
            if let replyTo = item.replyToName {
                Text(String(format: localized("回覆%@"), replyTo)).font(DSFont.caption).foregroundStyle(DSColor.textSecondary)
            }
            if !item.badges.isEmpty {
                Text(item.badges.map { $0.hasPrefix("data:") ? localized("徽章") : $0 }.joined(separator: " · "))
                    .font(DSFont.caption).foregroundStyle(DSColor.textSecondary)
            }
            if !item.text.isEmpty { Text(item.text).font(DSFont.body).textSelection(.enabled) }
            if let image = publicURL(item.image) { Link(localized("查看圖片"), destination: image) }
            if let audio = publicURL(item.audio) { Link(localized("開啟音訊附件"), destination: audio) }
            if let count = item.likeCount { Text(String(format: localized("%d個讚"), count)).font(DSFont.caption).foregroundStyle(DSColor.textSecondary) }
        }
    }
    @ViewBuilder
    private func reviewByline(_ item: NativeReviewItem) -> some View {
        if !item.name.isEmpty { Text(item.name).font(DSFont.bodyBold) }
        if let time = item.time { Text(time).font(DSFont.caption).foregroundStyle(DSColor.textSecondary) }
    }

    private func publicURL(_ raw: String?) -> URL? {
        guard let raw, let url = URL(string: raw), ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.user == nil, url.password == nil else { return nil }
        return url
    }
}

#Preview {
    NativeReviewView(selection: .init(book: ReadingBook(title: "段评预览", contentFilename: ""),
        source: BookSource(bookSourceUrl: "https://preview.invalid", bookSourceName: "预览"), chapter: .init(index: 0, title: "章", url: "https://preview.invalid/chapter")))
}
