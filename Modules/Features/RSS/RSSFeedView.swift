import SwiftUI
import SafariServices

// MARK: - SafariView

/// Takes `InAppWebURL`, not `URL`: `SFSafariViewController` raises on any scheme but
/// http(s), so callers route links through `RSSLinkRoute` first.
struct SafariView: UIViewControllerRepresentable {
    let url: InAppWebURL

    func makeUIViewController(context: Context) -> SFSafariViewController {
        SFSafariViewController(url: url.url)
    }

    func updateUIViewController(_ uiViewController: SFSafariViewController, context: Context) {}
}

// MARK: - RSSSmartFeedView

struct RSSSmartFeedView: View {
    let kind: RSSSmartFeedKind

    @StateObject private var store: RSSStore

    @State private var filter: RSSArticleTimelineFilter = .all
    @State private var searchText = ""
    @State private var selectedArticleID: String?

    init(kind: RSSSmartFeedKind, store: RSSStore = .shared) {
        self.kind = kind
        _store = StateObject(wrappedValue: store)
    }

    private let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .short
        return f
    }()

    private var articles: [RSSArticleRecord] {
        filter.apply(to: store.articles(for: kind), query: searchText)
    }

    private var unreadCount: Int {
        store.unreadCount(for: kind)
    }

    var body: some View {
        Group {
            if articles.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: kind.systemImage)
                        .font(DSFont.largeTitle)
                        .foregroundColor(DSColor.textSecondary)

                    Text(emptyMessage)
                        .foregroundColor(DSColor.textSecondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(articles) { article in
                        if let source = store.source(id: article.sourceId) {
                            Button {
                                store.markRead(articleId: article.id, isRead: true)
                                selectedArticleID = article.id
                            } label: {
                                RSSArticleRow(
                                    source: source,
                                    article: article,
                                    timeFormatter: timeFormatter
                                )
                            }
                            .buttonStyle(.plain)
                            .listRowInsets(EdgeInsets())
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                            .swipeActions(edge: .leading) {
                                Button {
                                    store.toggleFavorite(articleId: article.id)
                                } label: {
                                    Label(
                                        article.isFavorite ? localized("取消收藏") : localized("收藏"),
                                        systemImage: article.isFavorite ? "star.slash" : "star"
                                    )
                                }
                                .tint(.yellow)
                            }
                            .swipeActions(edge: .trailing) {
                                Button {
                                    store.markRead(articleId: article.id, isRead: !article.isRead)
                                } label: {
                                    Label(
                                        article.isRead ? localized("標為未讀") : localized("標為已讀"),
                                        systemImage: article.isRead ? "envelope.badge" : "envelope.open"
                                    )
                                }
                                .tint(DSColor.swipeAction)
                            }
                        }
                    }
                }
                .softScrollEdges()
                .listStyle(.plain)
            }
        }
        .toolbarTitleDisplayMode(.inline)
        .themedAppSurface(for: .rss)
        .hidesRootTabBar()
        .navigationDestination(item: $selectedArticleID) { articleID in
            RSSArticleReaderView(articleID: articleID)
        }
        .rssFeedSearchBarIfAvailable(searchText: $searchText)
        .toolbar {
            ToolbarItem(placement: .principal) {
                VStack(spacing: 1) {
                    Text(kind.title)
                        .font(DSFont.headline.weight(.semibold))
                        .foregroundColor(DSColor.textPrimary)
                        .lineLimit(1)

                    Text(String(format: localized("%d 未讀"), unreadCount))
                        .font(DSFont.caption)
                        .foregroundColor(DSColor.textSecondary)
                }
            }

            ToolbarItem(placement: .navigationBarTrailing) {
                Menu {
                    Picker("", selection: $filter) {
                        ForEach(RSSArticleTimelineFilter.allCases) { filter in
                            Label(filter.title, systemImage: filter.systemImage)
                                .tag(filter)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()

                    Divider()

                    Button {
                        store.markAllRead(smartFeed: kind)
                    } label: {
                        Label(localized("標記全部已讀"), systemImage: "checkmark.circle")
                    }
                    .disabled(unreadCount == 0)
                } label: {
                    Label(localized("篩選"), systemImage: "line.3.horizontal.decrease")
                        .labelStyle(.iconOnly)
                        .font(DSFont.toolbarIcon)
                }
                .foregroundColor(DSColor.textPrimary)
                .id("\(Locale.autoupdatingCurrent.identifier)_rss_smart_filter")
            }
        }
    }

    private var emptyMessage: String {
        switch filter {
        case .all:
            switch kind {
            case .today:
                return localized("沒有今日文章")
            case .allUnread:
                return localized("沒有未讀文章")
            case .starred:
                return localized("沒有加星文章")
            }
        case .unread:
            return localized("沒有未讀文章")
        case .read:
            return localized("沒有已讀文章")
        case .favorite:
            return localized("沒有收藏文章")
        }
    }
}

// MARK: - RSSFeedView

struct RSSFeedView: View {
    let source: RSSSource
    @Environment(\.openURL) private var openURL
    @StateObject private var store: RSSStore
    @State private var session: RSSFeedSession
    @State private var filter: RSSArticleTimelineFilter = .all
    @State private var searchText = ""
    @State private var submittedSearch: String?
    @State private var selectedSortEntry: RSSSortEntry?
    @State private var selectedArticleID: String?
    private struct PagePresentation: Identifiable {
        let id = UUID()
        var target: RSSOpenTarget
    }
    @State private var presentation: PagePresentation?
    @State private var autoOpenedWebPage = false

    init(source: RSSSource, store: RSSStore = .shared, entries: [RSSSortEntry]? = nil, query: String? = nil, resolvesEntry: Bool = true) {
        self.source = source
        _store = StateObject(wrappedValue: store)
        _session = State(initialValue: RSSFeedSession(source: source, store: store, resolvesEntry: resolvesEntry, entries: entries))
        _selectedSortEntry = State(initialValue: entries?.first)
        _submittedSearch = State(initialValue: query)
        _searchText = State(initialValue: query ?? "")
    }

    private let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter
    }()

    private struct LoadKey: Hashable {
        var revision: UInt64
        var category: String?
        var search: String?
    }
    private var loadKey: LoadKey {
        .init(revision: store.configurationRevision, category: selectedSortEntry?.id, search: submittedSearch)
    }
    private var currentSource: RSSSource { store.source(id: source.id) ?? source }
    private var supportsRemoteSearch: Bool {
        currentSource.searchUrl?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }
    private var articles: [RSSArticleRecord] {
        let records = store.articles(for: source.id, scope: session.scope)
        return filter.apply(to: records, query: supportsRemoteSearch ? "" : searchText)
    }
    private var unreadCount: Int { store.unreadCount(for: source.id) }

    var body: some View {
        List {
            if session.entries.count > 1 {
                Picker(localized("分類"), selection: Binding(
                    get: { selectedSortEntry ?? session.entries.first },
                    set: { selectedSortEntry = $0; submittedSearch = nil; searchText = "" }
                )) {
                    ForEach(session.entries) { entry in
                        Text(entry.name.isEmpty ? localized("全部") : entry.name).tag(Optional(entry))
                    }
                }
                .pickerStyle(.menu)
                .listRowBackground(Color.clear)
            }

            if let target = session.openTarget {
                webPageSourceContent(target: target)
            } else if articles.isEmpty {
                if session.isLoading {
                    ProgressView().frame(maxWidth: .infinity)
                        .listRowBackground(Color.clear)
                } else {
                    ContentUnavailableView {
                        UnavailableLabel(session.error == nil ? localized("目前沒有文章") : localized("重新載入"),
                                         systemImage: session.error == nil ? "newspaper" : "exclamationmark.triangle")
                    } description: {
                        if let error = session.error { Text(error) }
                    } actions: {
                        if session.canRetry {
                            Button(localized("重試")) { Task { await session.retry() } }
                        }
                        if let url = session.webPageFallbackURL {
                            Button(localized("以網頁開啟")) { show(.request(URLRequest(url: url.url))) }
                        }
                    }
                    .listRowBackground(Color.clear)
                }
            } else {
                ForEach(articles) { article in
                    Button {
                        store.markRead(articleId: article.id, isRead: true)
                        selectedArticleID = article.id
                    } label: {
                        RSSArticleRow(source: currentSource, article: article, timeFormatter: timeFormatter)
                    }
                    .accessibilityIdentifier("rss.article.\(article.id)")
                    .buttonStyle(.plain)
                    .listRowInsets(EdgeInsets())
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                    .swipeActions(edge: .leading) {
                        Button { store.toggleFavorite(articleId: article.id) } label: {
                            Label(article.isFavorite ? localized("取消收藏") : localized("收藏"),
                                  systemImage: article.isFavorite ? "star.slash" : "star")
                        }.tint(DSColor.accent)
                    }
                    .swipeActions(edge: .trailing) {
                        Button { store.markRead(articleId: article.id, isRead: !article.isRead) } label: {
                            Label(article.isRead ? localized("標為未讀") : localized("標為已讀"),
                                  systemImage: article.isRead ? "envelope.badge" : "envelope.open")
                        }.tint(DSColor.swipeAction)
                    }
                }
            }

            if session.isLoading {
                Button(localized("取消")) { session.cancel() }
                    .accessibilityIdentifier("rss.page.cancel")
                    .listRowBackground(Color.clear)
            } else if !articles.isEmpty, let error = session.error {
                Section {
                    Button(localized("重試")) { Task { await session.retry() } }
                        .accessibilityIdentifier("rss.page.retry")
                } footer: { Text(error).dsSectionFooter() }
                .listRowBackground(Color.clear)
            } else if session.canLoadMore {
                Button(localized("載入更多")) { Task { await session.nextPage() } }
                    .accessibilityIdentifier("rss.page.next")
                    .listRowBackground(Color.clear)
            }
            if session.wasCancelled {
                Text(localized("已取消")).foregroundStyle(DSColor.textSecondary)
                    .listRowBackground(Color.clear)
                if session.canRetry {
                    Button(localized("重試")) { Task { await session.retry() } }
                        .listRowBackground(Color.clear)
                }
            }
            if session.end == .budget || session.end == .loop {
                Text(session.end == .budget ? localized("已達分頁上限，已保留部分文章") : localized("分頁連結形成循環，已停止載入"))
                    .font(DSFont.footnote)
                    .foregroundStyle(DSColor.textSecondary)
                    .listRowBackground(Color.clear)
            }
        }
        .listStyle(.plain)
        .softScrollEdges()
        .toolbarTitleDisplayMode(.inline)
        .themedAppSurface(for: .rss)
        .hidesRootTabBar()
        .navigationDestination(item: $selectedArticleID) { articleID in
            RSSArticleReaderView(articleID: articleID, store: store)
        }
        .sheet(item: $presentation) { RSSSourcePageSheet(source: currentSource, target: $0.target, owner: store) }
        .rssFeedSearchBarIfAvailable(searchText: $searchText)
        .onSubmit(of: .search) {
            if supportsRemoteSearch { submittedSearch = searchText.trimmingCharacters(in: .whitespacesAndNewlines) }
        }
        .onChange(of: searchText) { _, value in
            if value.isEmpty { submittedSearch = nil }
        }
        .refreshable { await refresh() }
        .toolbar {
            ToolbarItem(placement: .principal) {
                VStack(spacing: DSSpacing.xs) {
                    Text(currentSource.name).font(DSFont.headline).lineLimit(1)
                    Text(String(format: localized("%d 未讀"), unreadCount)).font(DSFont.caption)
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker(localized("篩選"), selection: $filter) {
                        ForEach(RSSArticleTimelineFilter.allCases) { value in
                            Label(value.title, systemImage: value.systemImage).tag(value)
                        }
                    }
                    Button {
                        Task { await refresh() }
                    } label: {
                        Label(localized("刷新訂閱"), systemImage: "arrow.clockwise")
                    }.disabled(session.isLoading)
                } label: {
                    Label(localized("篩選"), systemImage: "line.3.horizontal.decrease")
                        .labelStyle(.iconOnly)
                }
            }
        }
        .task(id: loadKey) {
            if currentSource.usesLegadoRuntime || articles.isEmpty || submittedSearch != nil { await refresh() }
        }
        .onChange(of: session.openTarget) { _, target in
            if let target, !autoOpenedWebPage { autoOpenedWebPage = true; show(target) }
        }
        .onDisappear { session.cancel() }
    }

    private func refresh() async {
        await session.refresh(entry: selectedSortEntry, key: submittedSearch)
    }

    private func show(_ target: RSSOpenTarget) {
        if case .external(let url) = target {
            openURL(url) { accepted in if !accepted { RSSLinkRoute.logUnhandled(url) } }
        } else { presentation = PagePresentation(target: target) }
    }

    private func webPageSourceContent(target: RSSOpenTarget) -> some View {
        VStack(spacing: DSSpacing.md) {
            Text(currentSource.name).font(DSFont.headline)
            Text(localized("此訂閱源以網頁方式瀏覽")).foregroundStyle(DSColor.textSecondary)
            Button(localized("開啟網頁")) { show(target) }.buttonStyle(.onAccentProminent)
        }
        .frame(maxWidth: .infinity)
        .listRowBackground(Color.clear)
    }
}

enum RSSArticleTimelineFilter: String, CaseIterable, Identifiable {
    case all
    case unread
    case read
    case favorite

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all:
            return localized("全部文章")
        case .unread:
            return localized("未讀文章")
        case .read:
            return localized("已讀文章")
        case .favorite:
            return localized("收藏文章")
        }
    }

    var systemImage: String {
        switch self {
        case .all:
            return "tray.full"
        case .unread:
            return "circle.fill"
        case .read:
            return "checkmark.circle"
        case .favorite:
            return "star.fill"
        }
    }

    func apply(to records: [RSSArticleRecord], query: String = "") -> [RSSArticleRecord] {
        let filtered: [RSSArticleRecord]
        switch self {
        case .all:
            filtered = records
        case .unread:
            filtered = records.filter { !$0.isRead }
        case .read:
            filtered = records.filter(\.isRead)
        case .favorite:
            filtered = records.filter(\.isFavorite)
        }

        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else { return filtered }

        return filtered.filter { article in
            article.title.localizedCaseInsensitiveContains(trimmedQuery)
                || article.summary.localizedCaseInsensitiveContains(trimmedQuery)
                || (article.author?.localizedCaseInsensitiveContains(trimmedQuery) ?? false)
        }
    }
}

private struct RSSArticleRow: View {
    let source: RSSSource
    let article: RSSArticleRecord
    let timeFormatter: DateFormatter

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 10) {
                statusIndicator
                    .frame(width: 12, height: 12)
                    .padding(.top, 4)

                VStack(alignment: .leading, spacing: 6) {
                    Text(article.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? localized("暫無資料") : article.title.trimmingCharacters(in: .whitespacesAndNewlines))
                        .font(DSFont.headline)
                        .fontWeight(.bold)
                        .foregroundColor(DSColor.textPrimary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)

                    if !article.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text(article.summary.trimmingCharacters(in: .whitespacesAndNewlines))
                            .font(DSFont.subheadline)
                            .foregroundColor(DSColor.textSecondary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                    }

                    HStack(alignment: .center, spacing: 6) {
                        RSSFaviconView(source: source, size: 16)
                        
                        Text(metadataText)
                            .font(DSFont.caption)
                            .fontWeight(.semibold)
                            .foregroundColor(DSColor.textSecondary)
                            .lineLimit(1)
                        
                        if let pubDate = article.pubDate {
                            Text("•")
                                .font(DSFont.caption)
                                .foregroundColor(DSColor.textSecondary)
                            Text(timeFormatter.string(from: pubDate))
                                .font(DSFont.caption)
                                .foregroundColor(DSColor.textSecondary)
                                .lineLimit(1)
                        }
                    }
                    .padding(.top, 2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                
                if let imageURL = article.imageURL, let url = URL(string: imageURL)?.upgradedToHTTPS() {
                    AsyncImage(url: url) { phase in
                        if let image = phase.image {
                            image
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                        } else if phase.error != nil {
                            Color.clear
                        } else {
                            Color.gray.opacity(0.1)
                        }
                    }
                    .frame(width: 60, height: 60)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .padding(.leading, 4)
                }
            }
            .padding(.vertical, 12)
            .padding(.horizontal, 16)
            
            Divider()
                .padding(.leading, 38)
                .opacity(0.5)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var statusIndicator: some View {
        if article.isFavorite {
            Image(systemName: "star.fill")
                .font(DSFont.fixed(size: 11, weight: .semibold))
                .foregroundColor(.yellow)
        } else if !article.isRead {
            Circle()
                .fill(DSColor.accent)
        } else {
            Color.clear
        }
    }

    private var metadataText: String {
        if let author = article.author?.trimmingCharacters(in: .whitespacesAndNewlines), !author.isEmpty {
            return "\(source.name) - \(author)"
        }
        return source.name
    }
}


private struct RSSFeedSearchBarIOS18: ViewModifier {
    @Binding var searchText: String

    func body(content: Content) -> some View {
        content
            .searchable(
                text: $searchText,
                placement: .toolbar,
                prompt: localized("搜尋文章")
            )
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
    }
}

@available(iOS 26.0, *)
private struct RSSFeedSearchBar: ViewModifier {
    @Binding var searchText: String

    func body(content: Content) -> some View {
        #if compiler(>=6.2)
        content
            .searchable(
                text: $searchText,
                placement: .toolbar,
                prompt: localized("搜尋文章")
            )
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .toolbar {
                DefaultToolbarItem(
                    kind: .search,
                    placement: .bottomBar
                )
            }
        #else
        content
            .searchable(
                text: $searchText,
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: localized("搜尋文章")
            )
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
        #endif
    }
}

private extension View {
    @ViewBuilder
    func rssFeedSearchBarIfAvailable(searchText: Binding<String>) -> some View {
        if #available(iOS 26.0, *) {
            self.modifier(RSSFeedSearchBar(searchText: searchText))
        } else {
            self.modifier(RSSFeedSearchBarIOS18(searchText: searchText))
        }
    }
}

@available(iOS 26.0, *)
private extension View {
    func rssFeedSearchBar(searchText: Binding<String>) -> some View {
        modifier(RSSFeedSearchBar(searchText: searchText))
    }
}
// MARK: - URL Identifiable conformance for sheet(item:)

extension URL: @retroactive Identifiable {
    public var id: String { absoluteString }
}

#Preview("Today") {
    NavigationStack {
        RSSSmartFeedView(kind: .today)
    }
}

#Preview("BBC RSS") {
    NavigationStack {
        RSSFeedView(source: RSSSource(
            name: "BBC",
            url: "https://feedx.net/rss/bbc.xml",
            sortOrder: 0
        ))
    }
}

#Preview("RSS Timeline Rows") {
    let source = RSSSource(
        id: "source-1",
        name: "Daring Fireball",
        url: "https://daringfireball.net/feeds/main",
        sortOrder: 0
    )
    let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .short
        return f
    }()
    let now = Date()
    return List {
        RSSArticleRow(
            source: source,
            article: RSSArticleRecord(item: RSSItem(
                id: "1",
                title: "Broadcast Booths Around Baseball Tip Their Caps to John Sterling",
                link: "https://example.com/1",
                pubDate: now,
                description: "Daring Fireball",
                author: nil,
                sourceId: source.id
            )),
            timeFormatter: formatter
        )
        .listRowInsets(EdgeInsets())

        RSSArticleRow(
            source: source,
            article: RSSArticleRecord(
                item: RSSItem(
                    id: "2",
                    title: "A supercut of context-free intertitles from Adam Curtis movies",
                    link: "https://example.com/2",
                    pubDate: now,
                    description: "kottke.org",
                    author: nil,
                    sourceId: source.id
                ),
                status: RSSArticleStatus(articleId: "2", isRead: true)
            ),
            timeFormatter: formatter
        )
        .listRowInsets(EdgeInsets())

        RSSArticleRow(
            source: source,
            article: RSSArticleRecord(
                item: RSSItem(
                    id: "3",
                    title: "SpaceX data center follow-up",
                    link: "https://example.com/3",
                    pubDate: now,
                    description: "Stephen Hackett blogs about the Anthropic data center follow-up.",
                    author: "Manton Reece",
                    sourceId: source.id
                ),
                status: RSSArticleStatus(articleId: "3", isFavorite: true)
            ),
            timeFormatter: formatter
        )
        .listRowInsets(EdgeInsets())
    }
    .softScrollEdges()
    .listStyle(.plain)
}
