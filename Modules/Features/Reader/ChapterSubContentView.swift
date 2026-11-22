import SwiftUI

struct ChapterSubContentSelection: Identifiable, Sendable {
    let bookID: UUID
    let chapterIndex: Int
    let kind: ChapterSubContent.Kind
    var id: String { bookID.uuidString + ":" + String(chapterIndex) }
    var title: String { kind == .lyric ? localized("歌詞") : localized("彈幕") }
}

/// 使用原生列表查看当前章副文；点击带时间的行定位播放，格式／取回失败保持可读错误。
struct ChapterSubContentView: View {
    let selection: ChapterSubContentSelection
    let onSeek: (Double) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var document: ChapterSubContentDocument?
    @State private var failure: String?
    @State private var loading = true

    var body: some View {
        NavigationStack {
            Group {
                if loading { ProgressView().accessibilityLabel(localized("載入中")) }
                else if let failure {
                    ContentUnavailableView(localized("副文無法載入"), systemImage: "exclamationmark.bubble", description: Text(failure))
                } else if let document, !document.cues.isEmpty {
                    List(document.cues) { cue in
                        if let seconds = cue.seconds {
                            Button { onSeek(seconds) } label: {
                                VStack(alignment: .leading, spacing: DSSpacing.xs) {
                                    Text(cue.text).font(DSFont.body).foregroundStyle(DSColor.textPrimary)
                                    if let time = cue.timeLabel { Text(time).font(DSFont.caption).foregroundStyle(DSColor.textSecondary) }
                                }
                            }
                            .accessibilityHint(localized("點兩下跳到此時間"))
                        } else { Text(cue.text).font(DSFont.body).textSelection(.enabled) }
                    }
                } else {
                    ContentUnavailableView(localized("此章沒有副文"), systemImage: "text.bubble")
                }
            }
            .navigationTitle(selection.title)
            .toolbarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }
                        .accessibilityLabel(localized("關閉"))
                }
            }
        }
        .task(id: selection.id) {
            loading = true; failure = nil; document = nil
            let key = selection
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    guard let content = BookSourceFetcher.chapterCacheRepository.loadChapterPackageSync(
                        bookId: key.bookID, chapterIndex: key.chapterIndex)?.subContent, content.kind == key.kind else {
                        return ChapterSubContentDocument(cues: [])
                    }
                    return try ChapterSubContentDocument.parse(content)
                }.value
                try Task.checkCancellation()
                document = result; loading = false
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                failure = (error as? SourceSubContentError)?.localizedDescription ?? localized("副文無法載入")
                loading = false
            }
        }
    }
}

#Preview {
    ChapterSubContentView(selection: .init(bookID: UUID(), chapterIndex: 0, kind: .lyric), onSeek: { _ in })
}
