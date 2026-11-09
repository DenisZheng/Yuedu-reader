import SwiftUI
import SafariServices
import WebKit

struct RSSArticleReaderView: View {
    let articleID: String

    @StateObject private var store: RSSStore
    @State private var readerMode: RSSArticleReaderMode = .reader
    @State private var isLoadingFullText = false
    @State private var fullTextError: String?
    @State private var originalTarget: RSSOpenTarget?
    @State private var originalPageLoading = true
    @State private var rulePageError: String?
    @State private var rulePageReloadID = UUID()
    @State private var selectedURL: InAppWebURL?
    @Environment(\.openURL) private var openURL
    /// 分享 payload waiting for this page's own share sheet. This view is a
    /// `navigationDestination`, so that sheet is a first-level presentation — the
    /// toolbar `Menu` cannot own the share sheet itself before iOS 18. See
    /// `MenuShareLinkPresentationPolicy`.
    @State private var pendingShare: PendingShareExport<URL>?
    @State private var findRequestID: UUID?
    @State private var sourceFaviconURLs: [URL] = []
    @State private var webActions = RSSWebActionRouter()
    @State private var isReaderVisible = false

    init(articleID: String, store: RSSStore = .shared) {
        self.articleID = articleID
        _store = StateObject(wrappedValue: store)
    }

    private var article: RSSArticleRecord? {
        store.article(id: articleID)
    }

    private var source: RSSSource? {
        guard let article else { return nil }
        return store.source(id: article.sourceId)
    }

    var body: some View {
        Group {
            if let article {
                Group {
                    if let source, article.contentType == .image || article.contentType == .video {
                        RSSTypedArticleView(article: article, source: source, owner: store)
                    } else if let target = ruleTarget(for: article), let source {
                        RSSSourcePageWebView(source: source, target: target, error: $rulePageError, loading: $originalPageLoading, owner: store,
                                             findRequestID: $findRequestID, restoreScrollY: article.readerScrollY,
                                             onScrollYChange: { store.updateReaderScrollY(articleId: article.id, scrollY: $0) }, article: article,
                                             onAction: { try webActions.receive($0, source: source, owner: store) },
                                             isActive: isReaderVisible && selectedURL == nil && pendingShare == nil)
                            .id(rulePageReloadID)
                            .overlay(alignment: .top) {
                                if originalPageLoading { ProgressView().padding(DSSpacing.md) }
                                if let message = rulePageError ?? fullTextError {
                                    Text(message).font(DSFont.footnote).padding(DSSpacing.md).background(DSColor.surface)
                                }
                            }
                    } else {
                        RSSArticleWebReaderView(
                            document: document(for: article),
                            restoreScrollY: article.readerScrollY,
                            findRequestID: $findRequestID,
                            onScrollYChange: { scrollY in
                                store.updateReaderScrollY(articleId: article.id, scrollY: scrollY)
                            },
                            onOpenLink: { route in open(route) }
                        )
                    }
                }
                .ignoresSafeArea(.container, edges: .bottom)
                .navigationTitle(navigationTitle(for: article))
                .toolbarTitleDisplayMode(.inline)
                .pageBackgroundToolbar(for: .rss)
                .hidesRootTabBar()
                .toolbar {
                    ToolbarItemGroup(placement: .navigationBarTrailing) {
                        Button {
                            store.toggleFavorite(articleId: article.id)
                        } label: {
                            Label(
                                article.isFavorite ? localized("取消收藏") : localized("收藏"),
                                systemImage: article.isFavorite ? "star.fill" : "star"
                            )
                        }

                        Button {
                            findRequestID = UUID()
                        } label: {
                            Label(localized("搜尋文章"), systemImage: "magnifyingglass")
                        }

                        Menu {
                            if let media = article.media, !media.isEmpty, let source {
                                Section(localized("附件")) {
                                    ForEach(media) { attachment in
                                        Button {
                                            if attachment.kind == .image {
                                                let base = URL(string: article.link) ?? source.articleLinkBaseURL
                                                webActions.destination = .init(target: .photo(source, attachment.url, base, false, nil))
                                            } else {
                                                webActions.playMedia(attachment, article: article, source: source, owner: store)
                                            }
                                        } label: {
                                            Label(attachmentTitle(attachment), systemImage: attachment.kind == .image ? "photo" : attachment.kind == .audio ? "waveform" : "play.rectangle")
                                        }
                                        .accessibilityIdentifier("rss.attachment." + String(attachment.kind.rawValue))
                                    }
                                }
                            }
                            if rulePageError != nil {
                                Button(localized("重試")) { rulePageReloadID = UUID() }
                            }
                            if fullTextError != nil || article.fullTextIsPartial == true {
                                Button(localized("重試")) { Task { await loadFullTextIfNeeded(article) } }
                            }
                            Button {
                                toggleReaderMode()
                            } label: {
                                Label(readerModeToggleTitle, systemImage: readerModeToggleIcon)
                            }

                            let articleRoute = linkRoute(for: article)
                            if let url = articleRoute.url {
                                MenuShareRow(
                                    label: localized("分享"),
                                    makeExport: {
                                        PendingShareExport(
                                            title: localized("分享"),
                                            name: article.title,
                                            item: url
                                        )
                                    },
                                    onHandoff: { pendingShare = $0 }
                                )

                                Button {
                                    open(articleRoute)
                                } label: {
                                    Label(localized("原文"), systemImage: "safari")
                                }
                            }
                        } label: {
                            Label(localized("更多"), systemImage: "ellipsis")
                                .labelStyle(.iconOnly)
                        }
                    }
                }
                .task(id: article.id) {
                    store.markRead(articleId: article.id, isRead: true)
                    guard article.contentType != .image, article.contentType != .video else { return }
                    await loadFullTextIfNeeded(article)
                }
                .task(id: sourceFaviconLoadKey(for: article)) {
                    await loadSourceFaviconURLs()
                }
            } else {
                ContentUnavailableView {
                    UnavailableLabel(localized("目前沒有文章"), systemImage: "newspaper")
                } description: {
                    Text(localized("重新載入")).font(DSFont.unavailableDescription).foregroundStyle(DSColor.textSecondary)
                }
            }
        }
        .modifier(RSSWebActionPresentation(router: webActions, owner: store))
        .onAppear { isReaderVisible = true }
        .onDisappear { isReaderVisible = false; webActions.cancelPending() }
        .sheet(item: $pendingShare) { export in
            ShareExportSheet(export: export)
        }
        .sheet(item: $selectedURL) { url in
            SafariView(url: url)
        }
    }

    private func attachmentTitle(_ media: RSSMediaReference) -> String {
        let fallback = URL(string: media.url)?.lastPathComponent ?? localized("附件")
        return String((fallback.isEmpty ? localized("附件") : fallback).prefix(160))
    }

    /// The article's own link, resolved against its source — feeds and Legado rules
    /// can store a relative path or a non-web scheme here.
    private func linkRoute(for article: RSSArticleRecord) -> RSSLinkRoute {
        RSSLinkRoute.route(article.link, relativeTo: source?.articleLinkBaseURL)
    }

    private func open(_ route: RSSLinkRoute) {
        switch route {
        case .inApp(let webURL):
            selectedURL = webURL
        case .system(let url):
            openURL(url) { accepted in
                if !accepted { RSSLinkRoute.logUnhandled(url) }
            }
        case .unopenable:
            break
        }
    }

    private var readerModeToggleTitle: String {
        switch readerMode {
        case .feed:
            return localized("Reader View")
        case .reader:
            return localized("顯示摘要")
        }
    }

    private var readerModeToggleIcon: String {
        switch readerMode {
        case .feed:
            return "doc.plaintext"
        case .reader:
            return "doc.text"
        }
    }

    private func ruleTarget(for article: RSSArticleRecord) -> RSSOpenTarget? {
        guard let source, RSSArticleContentService.usesRules(source) else { return nil }
        let content = bodyHTML(for: article)
        if !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let base = RSSLinkRoute.route(article.link, relativeTo: source.articleLinkBaseURL).url?.absoluteString ?? article.link
            return .articleHTML(content, baseURL: base)
        }
        return originalTarget
    }

    private func document(for article: RSSArticleRecord) -> RSSArticleHTMLDocument {
        RSSArticleHTMLRenderer.render(
            article: article,
            source: source,
            mode: readerMode,
            bodyHTML: bodyHTML(for: article),
            fallbackText: fallbackText(for: article),
            sourceFaviconURLs: sourceFaviconURLs,
            isLoading: readerMode == .reader && isLoadingFullText,
            errorMessage: readerMode == .reader ? fullTextError ?? (article.fullTextIsPartial == true ? localized("正文尚未完整載入，已保留部分內容") : nil) : nil
        )
    }

    private func navigationTitle(for article: RSSArticleRecord) -> String {
        let title = article.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !title.isEmpty {
            return title
        }
        return source?.name ?? localized("RSS 訂閱")
    }

    private func bodyHTML(for article: RSSArticleRecord) -> String {
        switch readerMode {
        case .feed:
            return article.contentHTML
        case .reader:
            if shouldPreferFeedContent(article) {
                return article.contentHTML
            }
            if let html = article.fullTextHTML?.trimmingCharacters(in: .whitespacesAndNewlines), !html.isEmpty {
                return html
            }
            return article.contentHTML
        }
    }

    private func fallbackText(for article: RSSArticleRecord) -> String {
        switch readerMode {
        case .feed:
            return article.summary
        case .reader:
            if let fullText = article.fullText?.trimmingCharacters(in: .whitespacesAndNewlines), !fullText.isEmpty {
                return fullText
            }
            return article.summary
        }
    }

    private func toggleReaderMode() {
        readerMode = readerMode == .reader ? .feed : .reader
        if readerMode == .reader, let article {
            Task { await loadFullTextIfNeeded(article) }
        }
    }

    private func loadFullTextIfNeeded(_ article: RSSArticleRecord) async {
        if let source, RSSArticleContentService.needsOriginalPage(article, source: source) {
            guard !isLoadingFullText, originalTarget == nil else { return }
            isLoadingFullText = true
            defer { isLoadingFullText = false }
            do {
                let target = try await RSSOpenTarget.originalArticle(article, source: source, owner: store)
                try Task.checkCancellation()
                if case .external(let url) = target { open(.system(url)) }
                else { originalTarget = target }
            } catch is CancellationError { return }
            catch { fullTextError = error.localizedDescription }
            return
        }
        guard readerMode == .reader,
              !shouldPreferFeedContent(article),
              (article.fullTextHTML?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false || article.fullTextIsPartial == true),
              !isLoadingFullText else {
            return
        }

        isLoadingFullText = true
        fullTextError = nil
        defer { isLoadingFullText = false }

        do {
            let complete = try await RSSArticleContentService.load(article, source: source, store: store)
            if !complete { fullTextError = localized("正文尚未完整載入，已保留部分內容") }
        } catch is CancellationError { return }
        catch {
            fullTextError = fullTextErrorMessage(for: error)
        }
    }

    private func fullTextErrorMessage(for error: Error) -> String {
        if let loaderError = error as? RSSArticleContentLoaderError,
           case .httpStatus(403) = loaderError {
            return error.localizedDescription
        }
        return String(format: localized("全文抓取失敗：%@"), error.localizedDescription)
    }

    private func shouldPreferFeedContent(_ article: RSSArticleRecord) -> Bool {
        RSSArticleContentService.prefersDescription(article, source: source)
    }

    private func sourceFaviconLoadKey(for article: RSSArticleRecord) -> String {
        [
            article.sourceId,
            source?.url ?? "",
            source?.homepageURL ?? "",
            source?.displayFaviconURL ?? "",
            article.link
        ].joined(separator: "|")
    }

    @MainActor
    private func loadSourceFaviconURLs() async {
        guard let source else {
            sourceFaviconURLs = []
            return
        }
        let articleURL = article.flatMap { linkRoute(for: $0).url?.upgradedToHTTPS() }
        sourceFaviconURLs = await RSSFaviconResolver.candidateURLs(for: source, fallbackURL: articleURL)
    }
}

struct RSSArticleWebReaderView: UIViewRepresentable {
    let document: RSSArticleHTMLDocument
    let restoreScrollY: Double
    @Binding var findRequestID: UUID?
    let onScrollYChange: (Double) -> Void
    let onOpenLink: (RSSLinkRoute) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.userContentController.add(context.coordinator, name: "scrollPosition")

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.backgroundColor = .clear
        webView.isOpaque = false
        webView.scrollView.backgroundColor = .clear
        webView.allowsBackForwardNavigationGestures = false
        // Native Safari-style find-in-page (find bar, match count, prev/next,
        // highlighting). Also enables ⌘F with a hardware keyboard.
        webView.isFindInteractionEnabled = true
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.parent = self

        if context.coordinator.loadedHTML != document.html {
            context.coordinator.loadedHTML = document.html
            context.coordinator.pendingRestoreScrollY = restoreScrollY
            webView.loadHTMLString(document.html, baseURL: document.baseURL)
        }

        if let id = findRequestID, context.coordinator.lastFindRequestID != id {
            context.coordinator.lastFindRequestID = id
            webView.findInteraction?.presentFindNavigator(showingReplace: false)
        }
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var parent: RSSArticleWebReaderView
        var loadedHTML: String?
        var pendingRestoreScrollY: Double?
        var lastFindRequestID: UUID?

        init(_ parent: RSSArticleWebReaderView) {
            self.parent = parent
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            let scrollY = pendingRestoreScrollY ?? 0
            pendingRestoreScrollY = nil
            webView.evaluateJavaScript("window.yueduRestoreScrollY(\(scrollY));")
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
        ) {
            guard navigationAction.navigationType == .linkActivated,
                  let url = navigationAction.request.url else {
                decisionHandler(.allow)
                return
            }

            // Web links open in the Safari sheet and app links (mailto:, tel:) leave
            // for their app; everything else (in-page script, data:) stays with WebKit.
            let route = RSSLinkRoute.route(url)
            guard route != .unopenable else {
                decisionHandler(.allow)
                return
            }
            parent.onOpenLink(route)
            decisionHandler(.cancel)
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.name == "scrollPosition" else { return }
            if let value = message.body as? Double {
                parent.onScrollYChange(value)
            } else if let value = message.body as? Int {
                parent.onScrollYChange(Double(value))
            }
        }
    }
}

#Preview("RSS Article Reader") {
    NavigationStack {
        RSSArticleReaderPreview()
    }
}

private struct RSSArticleReaderPreview: View {
    @StateObject private var store = RSSStore.shared
    private let source = RSSSource(
        id: "preview-source",
        name: "BBC News",
        url: "https://feedx.net/rss/bbc.xml",
        homepageURL: "https://bbc.com/news"
    )
    private let originalKey = "https://example.com/rss-preview"
    private var articleID: String { RSSIdentity.article(sourceID: source.id, scope: .feed, rawKey: originalKey) }

    var body: some View {
        RSSArticleReaderView(articleID: articleID)
            .onAppear {
                if !store.sources.contains(where: { $0.id == source.id }) {
                    store.addSource(source)
                }
                if store.article(id: articleID) == nil {
                    store.mergeFetchedItems([
                        RSSItem(
                            id: originalKey,
                            title: "A supercut of context-free intertitles from Adam Curtis",
                            link: articleID,
                            pubDate: Date(),
                            description: "This is a preview summary paragraph.\n\nThe in-app reader renders RSS content as safe themed HTML.",
                            contentHTML: """
                            <p>This is a preview summary paragraph with a <a href="https://example.com/link">working link</a>.</p>
                            <p>The in-app reader renders RSS content as safe themed HTML.</p>
                            """,
                            author: "BBC News",
                            sourceId: source.id
                        )
                    ], for: source.id)
                    store.updateFullText(
                        articleId: articleID,
                        text: "This is extracted reader text.\n\nIt uses WebKit rendering, saved scroll position, toolbar actions, and find-in-article controls.",
                        html: """
                        <p>This is extracted reader text with <a href="https://example.com/full">reader-mode links</a>.</p>
                        <p>It uses WebKit rendering, saved scroll position, toolbar actions, and find-in-article controls.</p>
                        <figure><img src="https://example.com/image.jpg" alt="Preview image"><figcaption>Image captions survive sanitizing.</figcaption></figure>
                        """
                    )
                }
            }
    }
}
