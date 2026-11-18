import SwiftUI

/// articleStyle只决定列表呈现，不改变媒体类型、条目身份或分页合同。
enum RSSArticlePresentation: Int, CaseIterable {
    case list = 0, largeImage = 1, twoColumns = 2, masonry = 3, threeColumns = 4
    var isGrid: Bool { rawValue >= 2 }
    func columns(in size: CGSize, accessibility: Bool) -> Int {
        if accessibility { return 1 }
        switch self {
        case .twoColumns: return 2
        case .threeColumns: return 3
        case .masonry: return size.width > size.height ? 3 : 2
        default: return 1
        }
    }
}

/// List与媒体网格复用相同条目动作、分类及分页控件；不另建浏览状态或图片缓存。
struct RSSArticleCollection<Row: View, Header: View, Footer: View>: View {
    let articles: [RSSArticleRecord]
    let presentation: RSSArticlePresentation
    private let row: (RSSArticleRecord) -> Row
    private let onNearEnd: (() async -> Void)?
    private let preloadingIDs: Set<String>
    private let header: Header
    private let footer: Footer
    @Environment(\.dynamicTypeSize) private var dynamicType
    @State private var columns: [Column] = []

    init(articles: [RSSArticleRecord], presentation: RSSArticlePresentation,
         @ViewBuilder header: () -> Header, @ViewBuilder footer: () -> Footer,
         @ViewBuilder row: @escaping (RSSArticleRecord) -> Row,
         preloadDistance: Int = 1, onNearEnd: (() async -> Void)? = nil) {
        self.articles = articles; self.presentation = presentation
        self.header = header(); self.footer = footer(); self.row = row
        self.onNearEnd = onNearEnd
        // 只取最后1～5个稳定id，不为可见行在body里反复扫描全量列表。
        self.preloadingIDs = Set(articles.suffix(min(5, max(1, preloadDistance))).map(\.id))
    }

    var body: some View {
        if presentation.isGrid, !articles.isEmpty {
            GeometryReader { geometry in
                let count = presentation.columns(in: geometry.size, accessibility: dynamicType.isAccessibilitySize)
                ScrollView {
                    VStack(spacing: DSSpacing.md) {
                        header
                        if presentation == .masonry {
                            HStack(alignment: .top, spacing: DSSpacing.md) {
                                ForEach(columns) { column in
                                    LazyVStack(spacing: DSSpacing.md) {
                                        ForEach(column.articles) { entry in
                                            visibleRow(entry.article).accessibilitySortPriority(entry.priority)
                                        }
                                    }
                                    .frame(maxWidth: .infinity)
                                }
                            }
                            .task(id: Placement(articles: articles, count: count)) {
                                let value = await Self.place(articles, count: count)
                                if !Task.isCancelled { columns = value }
                            }
                        } else {
                            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: DSSpacing.md, alignment: .top), count: count), spacing: DSSpacing.md) {
                                ForEach(articles) { article in visibleRow(article) }
                            }
                        }
                        footer
                    }
                    .padding(DSSpacing.lg)
                }
            }
        } else {
            List {
                header
                ForEach(articles) { article in visibleRow(article) }
                footer
            }
            .listStyle(.plain)
        }
    }

    private func visibleRow(_ article: RSSArticleRecord) -> some View {
        row(article).task(id: articles.count) {
            if preloadingIDs.contains(article.id) { await onNearEnd?() }
        }
    }

    private struct Column: Identifiable, Sendable {
        let id: Int
        var articles: [Positioned]
    }
    private struct Positioned: Identifiable, Sendable {
        var id: String { article.id }
        let article: RSSArticleRecord
        let priority: Double
    }
    private struct Placement: Equatable {
        let articles: [RSSArticleRecord]
        let count: Int
    }
    /// 固定交错分列使图片尺寸变化时条目不换列，避免重新下载；每列懒加载并保留原条目身份。
    @concurrent private static func place(_ articles: [RSSArticleRecord], count: Int) async -> [Column] {
        SourcePerfTrace.span("rss.layout.columns", "main=\(Thread.isMainThread) articles=\(articles.count)") {
            var values = (0..<count).map { Column(id: $0, articles: []) }
            for (index, article) in articles.enumerated() {
                values[index % count].articles.append(Positioned(article: article, priority: Double(articles.count - index)))
            }
            return values
        }
    }
}

/// 装饰缩略图不观察整个store；请求/认证/文章变量与图片解码仍由唯一图片服务拥有。
struct RSSArticleThumbnail: View {
    /// 父视图可确认图片已进入可显示状态；只传条目身份，不暴露URL、凭据或第二份图片数据。
    struct ReadyImages: PreferenceKey {
        static let defaultValue: Set<String> = []
        static func reduce(value: inout Set<String>, nextValue: () -> Set<String>) { value.formUnion(nextValue()) }
    }
    let source: RSSSource
    let article: RSSArticleRecord
    let owner: RSSStore?
    var presentation: RSSArticlePresentation = .list
    @State private var image: UIImage?
    @State private var failed = false

    private struct Request: Equatable {
        let source: RSSSource
        let url: String?
        let variables: [String: String]?
        let title: String
        let link: String
        let category: String?
        let revision: UInt64
    }
    private var request: Request {
        .init(source: source, url: article.imageURL, variables: article.variables,
              title: article.title, link: article.link, category: article.categoryName,
              revision: owner?.runtimeRevision(for: source.id) ?? 0)
    }
    var body: some View {
        Group {
            if let image {
                if presentation == .masonry {
                    Image(uiImage: image).resizable().scaledToFit()
                } else {
                    GeometryReader { geometry in
                        Image(uiImage: image).resizable().scaledToFill()
                            .frame(width: geometry.size.width, height: geometry.size.height)
                            .clipped()
                    }
                }
            } else {
                ZStack {
                    DSColor.surfaceTertiary
                    if failed { Image(systemName: "exclamationmark.triangle").foregroundStyle(DSColor.textSecondary) }
                    else { ProgressView() }
                }
            }
        }
        .aspectRatio(presentation == .masonry && image != nil ? image!.size.width / max(1, image!.size.height)
            : presentation == .largeImage ? DSLayout.rssLargeImageAspectRatio : 1, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: DSRadius.sm))
        .accessibilityHidden(true)
        .preference(key: ReadyImages.self, value: image == nil ? [] : [article.id])
        .task(id: request) {
            image = nil; failed = false
            do {
                let value = try await RSSImageService.thumbnail(article, source: source, owner: owner)
                try Task.checkCancellation()
                image = value
            } catch is CancellationError {
                // 自己取消不显示错误；同源会话被其他操作撤销时不得永远停留在加载态。
                if !Task.isCancelled { failed = true }
            }
            catch { if !Task.isCancelled { failed = true } }
        }
    }
}

#Preview("RSS媒体列表样式") {
    let source = RSSSource(name: "Preview", url: "https://example.invalid")
    let article = RSSArticleRecord(item: RSSItem(id: "preview", title: "条目标题", link: "https://example.invalid/article", sourceId: source.id))
    RSSArticleCollection(articles: [article], presentation: .twoColumns, header: { EmptyView() }, footer: { EmptyView() }) { record in
        Text(record.title).font(DSFont.headline)
    }
}
