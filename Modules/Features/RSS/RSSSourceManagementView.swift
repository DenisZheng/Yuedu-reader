import SwiftUI

/// 选择按稳定源id保存；筛选不清除跨分类选择，源删除/恢复后只保留仍存在的id。
struct RSSSourceSelection {
    var ids: Set<String> = []
    mutating func retain(_ sources: [RSSSource]) { ids.formIntersection(sources.map(\.id)) }
    mutating func toggleAll(_ sources: [RSSSource]) {
        let visible = Set(sources.map(\.id))
        if visible.isSubset(of: ids) { ids.subtract(visible) } else { ids.formUnion(visible) }
    }
}

/// 原生List多选，沿用RSSStore的批量删除/请求失效合同，不复制持久化或网络流程。
struct RSSSourceManagementView: View {
    @ObservedObject var store: RSSStore
    @State private var selection = RSSSourceSelection()
    @State private var group = RSSSourceBrowse.allGroups
    @State private var query = ""
    @State private var visibleSources: [RSSSource] = []
    @State private var isLoadingSources = true
    @State private var deletionIDs: [String]?
    @State private var checker = RSSSourceHealthChecker()
    @State private var checkIDs: [String]?

    var body: some View {
        List(selection: $selection.ids) {
            Section {
                RSSSourceGroupPicker(folders: store.orderedFolders(), selection: $group)
                    .selectionDisabled()
            }
            Section {
                ForEach(visibleSources) { source in
                    VStack(alignment: .leading, spacing: DSSpacing.xs) {
                        Text(source.name).font(DSFont.body).foregroundStyle(DSColor.textPrimary)
                        Text(source.sourceGroup ?? localized("未分類"))
                            .font(DSFont.caption).foregroundStyle(DSColor.textSecondary)
                        if let result = checker.results[source.id] {
                            Text(result.title).font(DSFont.caption).foregroundStyle(DSColor.textSecondary)
                        }
                    }
                    .tag(source.id)
                    .accessibilityIdentifier("rss.manage.source.\(source.id)")
                }
            } footer: {
                Text(localized("全選只選取目前列表；跨分類選取會保留。"))
                    .dsSectionFooter()
                Text(localized("驗證結果只在本次管理頁面保留，不會自動停用或刪除源。"))
                    .dsSectionFooter()
            }
        }
        .overlay {
            if isLoadingSources {
                ProgressView().accessibilityLabel(localized("載入中…"))
            } else if visibleSources.isEmpty {
                ContentUnavailableView(localized("沒有訂閱源"), systemImage: "newspaper")
                    .allowsHitTesting(false)
            }
        }
        .environment(\.editMode, .constant(.active))
        .navigationTitle(localized("管理訂閱源"))
        .toolbarTitleDisplayMode(.inline)
        .themedAppSurface(for: .rss)
        .searchable(text: $query, prompt: localized("搜尋訂閱源"))
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    selection.toggleAll(visibleSources)
                } label: {
                    Text(localized(!visibleSources.isEmpty && Set(visibleSources.map(\.id)).isSubset(of: selection.ids) ? "取消全選" : "全選"))
                }
                .disabled(visibleSources.isEmpty)
                .accessibilityIdentifier("rss.manage.selectAll")
            }
        }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: DSSpacing.sm) {
                if checker.isRunning {
                    ProgressView(value: Double(checker.completed), total: Double(max(checker.total, 1)))
                        .accessibilityLabel(localized("驗證進度"))
                }
                Text(String(format: localized("已選 %d 個"), selection.ids.count))
                    .font(DSFont.caption).foregroundStyle(DSColor.textSecondary)
                HStack {
                    if checker.isRunning {
                        Button(localized("取消驗證")) { checker.cancel() }
                    } else {
                        Button(localized("驗證活性")) {
                            checkIDs = selection.ids.isEmpty ? visibleSources.map(\.id) : Array(selection.ids)
                        }
                        .disabled(visibleSources.isEmpty && selection.ids.isEmpty)
                        .accessibilityIdentifier("rss.manage.check")
                    }
                    Spacer()
                    Button(localized("刪除"), role: .destructive) {
                        deletionIDs = Array(selection.ids)
                    }
                    .disabled(selection.ids.isEmpty)
                    .accessibilityIdentifier("rss.manage.delete")
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            }
            .padding(DSSpacing.lg)
            .background(DSColor.surface)
        }
        .alert(localized("刪除訂閱源"), isPresented: Binding(get: { deletionIDs != nil }, set: { if !$0 { deletionIDs = nil } })) {
            Button(localized("刪除"), role: .destructive) {
                if let ids = deletionIDs {
                    store.removeSources(ids: ids)
                    selection.ids.subtract(ids)
                }
                deletionIDs = nil
            }
            Button(localized("取消"), role: .cancel) { deletionIDs = nil }
        } message: {
            Text(String(format: localized("確定刪除選取的 %d 個訂閱源及其文章、收藏和閱讀狀態嗎？此操作無法復原。"), deletionIDs?.count ?? 0))
        }
        .alert(localized("驗證活性"), isPresented: Binding(get: { checkIDs != nil }, set: { if !$0 { checkIDs = nil } })) {
            Button(localized("開始驗證")) {
                let ids = Set(checkIDs ?? [])
                checkIDs = nil
                checker.start(sources: store.sources.filter { ids.contains($0.id) }, owner: store)
            }
            Button(localized("取消"), role: .cancel) { checkIDs = nil }
        } message: {
            Text(localized("驗證會請求各源的啟動頁或首個分類列表，不抓取文章正文或載入媒體子資源。源腳本可能更新登入或變數；空列表和需互動會分開標示，網頁可達不代表影片可播。"))
        }
        .task(id: ManagementKey(revision: store.sourceBrowseRevision, group: group, query: query)) {
            isLoadingSources = true
            let sources = store.sources, folders = store.folders, currentGroup = group, search = query
            let result = await Task.detached(priority: .userInitiated) {
                RSSSourceBrowse.sources(sources, folders: folders, group: currentGroup, query: search)
            }.value
            guard !Task.isCancelled else { return }
            visibleSources = result
            isLoadingSources = false
            selection.retain(sources)
            checker.retainResults(for: sources)
        }
        .onChange(of: store.folders) { _, folders in
            if group != RSSSourceBrowse.allGroups && group != RSSSourceBrowse.ungrouped,
               !folders.contains(where: { RSSSourceBrowse.folder($0.id) == group }) { group = RSSSourceBrowse.allGroups }
        }
        .onDisappear { checker.cancel() }
    }

    private struct ManagementKey: Equatable {
        let revision: UInt64
        let group: String
        let query: String
    }
}

#Preview("订阅源多选维护") {
    NavigationStack { RSSSourceManagementView(store: RSSStore.shared) }
}
