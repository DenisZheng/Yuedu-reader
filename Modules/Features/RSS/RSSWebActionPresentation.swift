import SwiftUI

/// 同一NavigationStack中的原生目的页；网页不持有SwiftUI/Store对象。
struct RSSWebActionPresentation: ViewModifier {
    @Bindable var router: RSSWebActionRouter
    let owner: RSSStore?
    @Environment(\.openURL) private var openURL
    func body(content: Content) -> some View {
        content
            .navigationDestination(item: $router.destination) { destination in
                if let owner { RSSWebActionTargetView(target: destination.target, owner: owner) }
                else { ContentUnavailableView(localized("載入失敗"), systemImage: "exclamationmark.triangle") }
            }
            .alert(localized("確認網頁操作"), isPresented: Binding(get: { router.confirmation != nil }, set: { if !$0 { router.confirmation = nil } }), presenting: router.confirmation) { pending in
                Button(localized("繼續")) {
                    guard let owner else { return }
                    router.acceptConfirmation(owner: owner) { url in
                        openURL(url) { accepted in if !accepted { router.error = RSSWebFailure.navigationBlocked.localizedDescription } }
                    }
                }
                Button(localized("取消"), role: .cancel) { router.confirmation = nil }
            } message: { pending in
                Text(String(format: localized("網頁要求開啟 %@。將使用該來源的原生功能或外部應用程式。"), String(pending.display.prefix(256))))
            }
            .overlay(alignment: .top) {
                if router.isLoading { ProgressView().padding(DSSpacing.md) }
                if let error = router.error {
                    VStack(spacing: DSSpacing.sm) {
                        // 大字号下完整换行，不截断错误原因。
                        Text(error).font(DSFont.footnote)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                        Button(localized("關閉")) { router.error = nil }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(DSSpacing.md).background(DSColor.surface)
                    .accessibilityIdentifier("rss.web.actionError")
                }
            }
    }
}

private struct RSSWebActionTargetView: View {
    let target: RSSWebActionRouter.Target
    let owner: RSSStore
    @ViewBuilder var body: some View {
        switch target {
        case .feed(let source, let entries):
            if entries?.isEmpty == true { ContentUnavailableView(localized("尚無分類"), systemImage: "tray").toolbarTitleDisplayMode(.inline) }
            else { RSSFeedView(source: source, store: owner, entries: entries, resolvesEntry: false) }
        case .web(let source, let target, let title):
            RSSSourcePageScreen(source: source, target: target, owner: owner, title: title)
        case .search(let query, let scope): RSSNativeSearchView(query: query, scope: scope)
        case .login(let source): RSSSourceLoginView(source: source, owner: owner)
        case .photo(let source, let raw, let base, let rule, let context):
            RSSImageReaderView(source: source, rawURL: raw, baseURL: base, context: context, owner: owner, ruleURL: rule)
        case .book(let book): OnlineBookDetailDestination(.book(book))
        case .explore(let source, let url, let title): RSSNativeExploreView(source: source, url: url, title: title)
        case .video(let owner, let articleID, let attachmentKey, let stream, let resources, let title):
            if let owner { RSSArticleVideoPlayerView(owner: owner, articleID: articleID, attachmentKey: attachmentKey, stream: stream, resources: resources, title: title) }
            else { ContentUnavailableView(localized("載入失敗"), systemImage: "play.slash") }
        }
    }
}

/// 脚本搜索复用现有SearchView及临时scope，不改用户保存的全局搜索范围。
private struct RSSNativeSearchView: View {
    var query: String
    var scope: String?
    @State private var resolved: SearchSourceScope?
    @State private var isLoading = true
    var body: some View {
        Group {
            if isLoading { ProgressView() }
            else { SearchView(initialQuery: query, sessionScope: resolved) }
        }
        .toolbarTitleDisplayMode(.inline)
        .task {
            guard let scope else { isLoading = false; return }
            await BookSourceStore.shared.waitUntilLoaded()
            let sources = BookSourceStore.shared.sources
            resolved = await SourceScriptThread.run { Self.resolveScope(scope, sources: sources) }
            guard !Task.isCancelled else { return }
            isLoading = false
        }
    }
    nonisolated private static func resolveScope(_ raw: String, sources: [BookSource]) -> SearchSourceScope {
        guard !raw.isEmpty else { return .all }
        let selected: [BookSource]
        if let separator = raw.range(of: "::") {
            let url = String(raw[separator.upperBound...])
            selected = sources.filter { $0.bookSourceUrl == url }
        } else if let source = sources.first(where: { $0.bookSourceUrl == raw }) { selected = [source] }
        else {
            let groups = Set(raw.split(separator: ",").map(String.init))
            selected = sources.filter { !groups.isDisjoint(with: $0.bookSourceGroup.split(whereSeparator: { $0 == "," || $0 == ";" }).map(String.init)) }
        }
        // 空范围保持空；不能因源已删除/分组不存在而偷偷向全部源发送请求。
        return .init(mode: .custom, selectedSourceURLs: Set(selected.map(\.bookSourceUrl)))
    }
}

private struct RSSNativeExploreView: View {
    let source: BookSource
    let url: String
    let title: String
    @State private var section: DiscoverShowcaseSection?
    @State private var selected: RSSWebActionRouter.Destination?
    var body: some View {
        Group {
            if let section {
                DiscoverCategoryView(section: section, source: source) { book in selected = .init(target: .book(book)) }
            } else { ProgressView() }
        }
        .navigationTitle(title)
        .toolbarTitleDisplayMode(.inline)
        .navigationDestination(item: $selected) { destination in
            if case .book(let book) = destination.target { OnlineBookDetailDestination(.book(book)) }
        }
        .task {
            let headers = await BookSourceSession.session(for: source).resolvedHeaders()
            guard !Task.isCancelled else { return }
            let item = DiscoverCardItem(title: title, stableKey: url, raw: .init(title: title, url: url), isAction: false, actionURL: nil, isFetchable: true)
            section = DiscoverShowcaseSection(item: item, coverBaseURL: source.bookSourceUrl, coverHeaders: headers)
        }
    }
}

#Preview("RSS native action error") {
    let router = RSSWebActionRouter()
    router.error = RSSWebFailure.actionUnavailable.localizedDescription
    return NavigationStack { Text("Preview").modifier(RSSWebActionPresentation(router: router, owner: nil)) }
}
