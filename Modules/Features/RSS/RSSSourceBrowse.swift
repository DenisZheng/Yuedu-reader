import SwiftUI

/// 根页方格与源管理共用的显示投影；仅接收快照，不拥有源或文章状态。
enum RSSSourceBrowse {
    static let layoutKey = "rss_source_home_grid"
    static let allGroups = "all"
    static let ungrouped = "ungrouped"
    static func folder(_ id: String) -> String { "folder:" + id }

    nonisolated static func sources(_ sources: [RSSSource], folders: [RSSFolder], group: String = allGroups,
                                    query: String = "", unreadIDs: Set<String>? = nil) -> [RSSSource] {
        SourcePerfTrace.span("rss.sourceBrowse", "main=\(Thread.isMainThread) sources=\(sources.count)") {
            let folderName = folders.first { folder($0.id) == group }?.name
            let search = query.trimmingCharacters(in: .whitespacesAndNewlines)
            return sources.filter { source in
                let name = source.sourceGroup?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let matchesGroup = group == allGroups || (group == ungrouped && name.isEmpty)
                    || (folderName.map { name.caseInsensitiveCompare($0) == .orderedSame } ?? false)
                return matchesGroup && (unreadIDs.map { $0.contains(source.id) } ?? true)
                    && (search.isEmpty || source.name.localizedCaseInsensitiveContains(search)
                        || name.localizedCaseInsensitiveContains(search))
            }.sorted {
                if $0.sortOrder != $1.sortOrder { return $0.sortOrder < $1.sortOrder }
                let order = $0.name.localizedCaseInsensitiveCompare($1.name)
                return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
            }
        }
    }
}

struct RSSGridRefreshKey: Equatable {
    let revision: UInt64
    let group: String
    let hideRead: Bool
}

struct RSSSourceGroupPicker: View {
    let folders: [RSSFolder]
    @Binding var selection: String
    var body: some View {
        Picker(localized("訂閱分類"), selection: $selection) {
            Text(localized("全部分類")).tag(RSSSourceBrowse.allGroups)
            Text(localized("未分類")).tag(RSSSourceBrowse.ungrouped)
            ForEach(folders) { folder in
                Text(folder.name).tag(RSSSourceBrowse.folder(folder.id))
            }
        }
        .pickerStyle(.menu)
        .accessibilityIdentifier("rss.sourceGroup")
    }
}

/// 方形图标与两行源名称，原生NavigationLink仍由首页拥有，长按复用其源操作。
struct RSSSourceGridLabel: View {
    let source: RSSSource
    let unreadCount: Int
    @Environment(\.dynamicTypeSize) private var typeSize
    var body: some View {
        VStack(spacing: DSSpacing.sm) {
            RSSFaviconView(source: source, size: DSLayout.rssThumbnailSide)
                .accessibilityHidden(true)
            Text(source.name)
                .font(DSFont.subheadline)
                .foregroundStyle(DSColor.textPrimary)
                .lineLimit(typeSize.isAccessibilitySize ? nil : 2)
                .multilineTextAlignment(.center)
            if unreadCount > 0 {
                Text(String(format: localized("%d 未讀"), unreadCount))
                    .font(DSFont.caption)
                    .foregroundStyle(DSColor.textSecondary)
            }
        }
        .frame(maxWidth: .infinity, minHeight: DSLayout.minimumTapTarget, alignment: .top)
        .padding(DSSpacing.sm)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

#Preview("订阅方格") {
    RSSSourceGridLabel(source: RSSSource(name: "示例订阅源", url: "https://example.invalid/feed"), unreadCount: 3)
        .frame(width: DSLayout.rssSourceGridMinimumWidth)
}
