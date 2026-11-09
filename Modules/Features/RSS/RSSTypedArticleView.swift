import SwiftUI

/// Legado `ReadRss.readNoHtml`/`VideoPlay`：type=1/2 先用 ruleContent 得到资源地址（为空时用文章链接），
/// 再交给原生图片查看器或播放器；不把图片/视频结果当正文拼接，也不另存第二份进度。
struct RSSTypedArticleView: View {
    let article: RSSArticleRecord
    let source: RSSSource
    let owner: RSSStore
    @State private var model = RSSTypedArticleModel()
    @State private var retryID = UUID()

    var body: some View {
        Group {
            switch model.state {
            case .loading:
                ProgressView().accessibilityLabel(localized("載入中"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed(let message):
                ContentUnavailableView {
                    Label(localized("載入失敗"), systemImage: article.contentType == .video ? "play.slash" : "photo")
                } description: { Text(message) } actions: {
                    Button(localized("重試")) { retryID = UUID() }.accessibilityIdentifier("rss.typed.retry")
                }
            case .image(let url):
                RSSImageReaderView(source: source, rawURL: url, baseURL: URL(string: article.link) ?? source.articleLinkBaseURL,
                                   context: nil, owner: owner, ruleURL: true)
            case .video(let stream, let resources):
                RSSArticleVideoPlayerView(owner: owner, articleID: article.id, attachmentKey: "primary",
                                          stream: stream, resources: resources, title: article.title)
            }
        }
        .toolbarTitleDisplayMode(.inline)
        .task(id: retryID) { await model.load(article, source: source, owner: owner) }
        .onDisappear { model.release() }
    }
}

@MainActor @Observable final class RSSTypedArticleModel {
    enum State { case loading, failed(String), image(String), video(VideoStream, RSSMediaResourceSession) }
    private(set) var state: State = .loading
    @ObservationIgnored private var generation = 0

    func load(_ article: RSSArticleRecord, source: RSSSource, owner: RSSStore) async {
        release()
        let id = generation
        state = .loading
        do {
            let raw = try await Self.resourceURL(article, source: source, owner: owner)
            try Task.checkCancellation()
            guard id == generation, owner.article(id: article.id) != nil else { throw CancellationError() }
            if article.contentType == .video {
                if raw.hasPrefix("<") { throw VideoChapterLinkError.dashManifest }
                let prepared = try await RSSMediaRequestService.prepare(raw, source: source, base: URL(string: article.link),
                    context: nil, owner: owner, trustedRuleURL: true,
                    article: .init(title: article.title, link: article.link, category: article.categoryName ?? "", id: article.id))
                let (stream, resources) = try await RSSMediaRequestService.stream(prepared)
                guard id == generation, !Task.isCancelled else { resources.stop(); throw CancellationError() }
                state = .video(stream, resources)
            } else {
                state = .image(raw)
            }
        } catch is CancellationError { return }
        catch {
            guard id == generation else { return }
            state = .failed((error as? LocalizedError)?.errorDescription ?? RSSWebFailure.resourceUnavailable.localizedDescription)
        }
    }

    func release() {
        generation &+= 1
        if case .video(_, let resources) = state { resources.stop() }
    }

    /// ruleContent为空时链接本身就是资源；否则取正文首页结果并按文章链接补全相对地址。
    nonisolated static func resourceURL(_ article: RSSArticleRecord, source: RSSSource, owner: RSSStore) async throws -> String {
        let rule = source.ruleContent?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !rule.isEmpty else {
            let link = article.link.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !link.isEmpty else { throw RSSWebFailure.resourceUnavailable }
            return link
        }
        let result = try await LegadoRSSScraper.fetchArticleContentResult(source: source, articleLink: article.link, owner: owner,
            variables: article.variables ?? [:], categoryName: article.categoryName ?? "", articleTitle: article.title,
            articleType: article.contentType)
        let body = result.html.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { throw ScraperError.noArticlesFound }
        return absolute(body, base: article.link)
    }

    nonisolated static func absolute(_ raw: String, base: String) -> String {
        let lower = raw.lowercased()
        if raw.hasPrefix("<") || lower.hasPrefix("http://") || lower.hasPrefix("https://") || lower.hasPrefix("data:")
            || lower.hasPrefix("@js:") || raw.hasPrefix("<js>") || raw.hasPrefix("{{") { return raw }
        if lower.hasPrefix("javascript") { return "" }
        let plain = AnalyzeUrl.stripOptions(from: raw)
        let suffix = String(raw.dropFirst(plain.count))
        guard let baseURL = URL(string: AnalyzeUrl.cleanBaseURL(base)), let url = URL(string: plain, relativeTo: baseURL)?.absoluteURL else { return raw }
        return url.absoluteString + suffix
    }
}

#Preview("RSS typed article error") {
    let source = RSSSource(name: "Preview", url: "https://example.invalid")
    let article = RSSArticleRecord(item: RSSItem(id: "preview", title: "Preview", link: "", sourceId: source.id))
    return NavigationStack { RSSTypedArticleView(article: article, source: source, owner: RSSStore.shared) }
}
