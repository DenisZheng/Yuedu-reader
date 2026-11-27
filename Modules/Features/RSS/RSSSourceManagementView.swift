import SwiftUI

/// 普通源分组保留跨组勾选；结果页批选永远只作用于当前列表。
struct RSSSourceSelection {
    var ids: Set<String> = []
    mutating func retain(_ available: Set<String>) { ids.formIntersection(available) }
    mutating func toggleAll(_ visible: Set<String>, onlyPage: Bool = false) {
        if onlyPage { ids = ids == visible ? [] : visible }
        else if visible.isSubset(of: ids) { ids.subtract(visible) }
        else { ids.formUnion(visible) }
    }
    mutating func invert(_ visible: Set<String>) { ids = visible.subtracting(ids) }
}

/// 原生 List 多选，沿用 RSSStore 的批量删除和请求失效合同。
struct RSSSourceManagementView: View {
    @ObservedObject var store: RSSStore
    @State private var selection = RSSSourceSelection()
    @State private var group = RSSSourceBrowse.allGroups
    @State private var query = ""
    @State private var resultFilter: RSSManagementPages.Kind?
    @State private var pages = RSSManagementPages()
    @State private var appliedKey: ManagementKey?
    @State private var pendingDeletion: PendingDeletion?
    @State private var selectionInvalidated = false
    @State private var checker = RSSSourceHealthChecker()
    @State private var checkIDs: Set<String>?

    private var managementKey: ManagementKey {
        .init(revision: store.configurationRevision, group: group, query: query,
              isChecking: checker.isRunning, resultVersion: checker.resultVersion, revisions: store.requestRevisions)
    }
    private var isLoadingSources: Bool { appliedKey != managementKey }
    private var visiblePage: RSSManagementPages.Page {
        isLoadingSources ? .init() : pages.page(for: resultFilter)
    }

    var body: some View {
        let visible = visiblePage
        List(selection: $selection.ids) {
            Section {
                RSSSourceGroupPicker(folders: store.orderedFolders(), selection: $group)
                    .selectionDisabled()
                if !pages.byKind.isEmpty || resultFilter != nil {
                    resultPages.selectionDisabled()
                }
            }
            Section {
                ForEach(visible.rows) { source in
                    VStack(alignment: .leading, spacing: DSSpacing.xs) {
                        Text(source.name).font(DSFont.body).foregroundStyle(DSColor.textPrimary)
                        Text(source.sourceGroup ?? localized("未分類"))
                            .font(DSFont.caption).foregroundStyle(DSColor.textSecondary)
                        if pages.verifiedIDs.contains(source.id), let result = checker.results[source.id] {
                            Text(result.title).font(DSFont.caption).foregroundStyle(DSColor.textSecondary)
                        }
                    }
                    .tag(source.id)
                    .accessibilityIdentifier("rss.manage.source.\(source.id)")
                }
            } footer: {
                if selectionInvalidated {
                    Text(localized("列表已變更，請重新選取")).dsSectionFooter()
                }
                if resultFilter == nil {
                    Text(localized("全選只選取目前列表；跨分類選取會保留。")).dsSectionFooter()
                } else if resultFilter == .failed {
                    Text(localized("一次驗證失敗不代表永久失效。")).dsSectionFooter()
                }
                Text(localized("驗證結果只在本次管理頁面保留，不會自動停用或刪除源。"))
                    .dsSectionFooter()
            }
        }
        .overlay {
            if isLoadingSources {
                ProgressView().accessibilityLabel(localized("載入中…"))
            } else if visible.rows.isEmpty {
                ContentUnavailableView(
                    localized(resultFilter == nil ? "沒有訂閱源" : "沒有符合篩選的來源配置"),
                    systemImage: "newspaper"
                )
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
                    selection.toggleAll(visiblePage.ids, onlyPage: resultFilter != nil)
                    selectionInvalidated = false
                } label: {
                    Text(localized(!visible.ids.isEmpty && visible.ids.isSubset(of: selection.ids) ? "取消全選" : "全選"))
                }
                .disabled(visible.rows.isEmpty)
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
                            guard !isLoadingSources else { return }
                            let selected = selectedForDeletion
                            let ids = selected.isEmpty ? visiblePage.ids : selected
                            if !ids.isEmpty { checkIDs = ids }
                        }
                        .disabled(isLoadingSources || (visible.rows.isEmpty && selection.ids.isEmpty))
                        .accessibilityIdentifier("rss.manage.check")
                    }
                    Spacer()
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: DSSpacing.sm) { selectionActions }
                        VStack(alignment: .trailing, spacing: DSSpacing.sm) { selectionActions }
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            }
            .padding(DSSpacing.lg)
            .background(DSColor.surface)
        }
        .alert(localized("刪除訂閱源"), isPresented: Binding(get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } })) {
            Button(localized("刪除"), role: .destructive, action: deleteSelected)
            Button(localized("取消"), role: .cancel) { pendingDeletion = nil }
        } message: {
            Text(String(format: localized("確定刪除選取的 %d 個訂閱源及其文章、收藏和閱讀狀態嗎？此操作無法復原。"), pendingDeletion?.ids.count ?? 0))
        }
        .alert(localized("驗證活性"), isPresented: Binding(get: { checkIDs != nil }, set: { if !$0 { checkIDs = nil } })) {
            Button(localized("開始驗證")) {
                let ids = checkIDs ?? []
                checkIDs = nil
                if resultFilter != nil {
                    selection.ids = []
                    resultFilter = nil
                }
                selectionInvalidated = false
                checker.start(sources: store.sources.filter { ids.contains($0.id) }, owner: store)
            }
            Button(localized("取消"), role: .cancel) { checkIDs = nil }
        } message: {
            Text(localized("驗證會請求各源的啟動頁或首個分類列表，不抓取文章正文或載入媒體子資源。源腳本可能更新登入或變數；空列表和需互動會分開標示，網頁可達不代表影片可播。"))
        }
        .task(id: managementKey) { await rebuildPages(for: managementKey) }
        .onChange(of: store.folders) { _, folders in
            if group != RSSSourceBrowse.allGroups && group != RSSSourceBrowse.ungrouped,
               !folders.contains(where: { RSSSourceBrowse.folder($0.id) == group }) { group = RSSSourceBrowse.allGroups }
        }
        .onDisappear { checker.cancel() }
    }

    private var selectedForDeletion: Set<String> {
        resultFilter == nil ? selection.ids : selection.ids.intersection(visiblePage.ids)
    }

    @ViewBuilder private var selectionActions: some View {
        Button(localized("反選")) {
            guard !isLoadingSources else { return }
            selection.invert(visiblePage.ids)
            selectionInvalidated = false
        }
        .disabled(visiblePage.rows.isEmpty)
        .accessibilityIdentifier("rss.manage.invertSelection")
        Button(localized("刪除"), role: .destructive) {
            guard !isLoadingSources else { return }
            let ids = selectedForDeletion
            guard !ids.isEmpty else { return }
            pendingDeletion = .init(ids: ids, resultFilter: resultFilter, key: resultFilter == nil ? nil : managementKey)
        }
        .disabled(isLoadingSources || selection.ids.isEmpty)
        .accessibilityIdentifier("rss.manage.delete")
    }

    private var resultPages: some View {
        let kinds = RSSManagementPages.Kind.allCases.filter { pages.byKind[$0] != nil || resultFilter == $0 }
        return ScrollView(.horizontal) {
            HStack(spacing: DSSpacing.sm) {
                resultButton(nil, title: localized("全部"))
                ForEach(kinds, id: \.self) { kind in
                    resultButton(kind, title: kind.title)
                }
            }
            .padding(.vertical, DSSpacing.xs)
        }
        .scrollIndicators(.hidden)
        .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
        .disabled(isLoadingSources || checker.isRunning)
    }

    @ViewBuilder private func resultButton(_ kind: RSSManagementPages.Kind?, title: String) -> some View {
        let selected = resultFilter == kind
        let button = Button {
            guard !selected, !isLoadingSources, !checker.isRunning else { return }
            selection.ids = []
            selectionInvalidated = false
            resultFilter = kind
        } label: {
            HStack(spacing: DSSpacing.xs) {
                if selected {
                    Image(systemName: "checkmark").accessibilityHidden(true)
                }
                Text("\(title) \(pages.page(for: kind).rows.count)")
                    .monospacedDigit()
            }
            .font(DSFont.subheadline)
        }
        .accessibilityIdentifier("rss.manage.health.\(kind?.rawValue ?? "all")")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .buttonBorderShape(.capsule)
        .controlSize(.large)
        if selected { button.buttonStyle(.onAccentProminent) }
        else { button.buttonStyle(.bordered) }
    }

    private func deleteSelected() {
        guard let pendingDeletion else { return }
        self.pendingDeletion = nil
        // 确认期间若已换页、重查或改配置，原结果不得再驱动删除。
        if let key = pendingDeletion.key, key != managementKey || pendingDeletion.resultFilter != resultFilter {
            selection.ids = []
            selectionInvalidated = true
            return
        }
        store.removeSources(ids: Array(pendingDeletion.ids))
        selection.ids.subtract(pendingDeletion.ids)
    }

    private func rebuildPages(for key: ManagementKey) async {
        guard appliedKey != key else { return }
        let sources = store.sources, folders = store.folders
        let scoped = await Task.detached(priority: .userInitiated) {
            RSSSourceBrowse.sources(sources, folders: folders, group: key.group, query: key.query)
        }.value
        guard !Task.isCancelled, key == managementKey else { return }
        let groups = if let revisions = key.revisions {
            await checker.selectionGroups(in: scoped, revisions: revisions)
        } else { [RSSSourceHealthChecker.SelectionGroup]() }
        let value = await Task.detached(priority: .userInitiated) {
            RSSManagementPages.make(library: sources, scoped: scoped, groups: groups)
        }.value
        guard !Task.isCancelled, key == managementKey else { return }
        if appliedKey?.revision != key.revision { checker.retainResults(for: sources) }
        pages = value
        selection.retain(resultFilter == nil ? value.libraryIDs : value.page(for: resultFilter).ids)
        appliedKey = key
    }

    private struct ManagementKey: Equatable, Sendable {
        let revision: UInt64
        let group: String
        let query: String
        let isChecking: Bool
        let resultVersion: UInt64
        let revisions: RSSStore.RequestRevisions?
    }

    private struct PendingDeletion {
        let ids: Set<String>
        let resultFilter: RSSManagementPages.Kind?
        let key: ManagementKey?
    }
}

/// 展示用行和页内索引从当前分组与搜索范围生成；检查结果仍由 checker 持有。
private struct RSSManagementPages: Sendable {
    typealias Kind = RSSSourceHealthChecker.Outcome.Kind

    struct Page: Sendable {
        var rows: [RSSSource] = []
        var ids: Set<String> = []
    }
    var libraryIDs: Set<String> = []
    var verifiedIDs: Set<String> = []
    var all = Page()
    var byKind: [Kind: Page] = [:]

    func page(for kind: Kind?) -> Page {
        if let kind { return byKind[kind] ?? .init() }
        return all
    }

    nonisolated static func make(library: [RSSSource], scoped: [RSSSource], groups: [RSSSourceHealthChecker.SelectionGroup]) -> Self {
        SourcePerfTrace.span("rss.management.pages", "main=\(Thread.isMainThread) sources=\(scoped.count)") {
            var value = Self(libraryIDs: Set(library.map(\.id)))
            var kindByID: [String: Kind] = [:]
            for group in groups {
                value.byKind[group.kind] = Page(ids: group.sourceIDs)
                for id in group.sourceIDs { kindByID[id] = group.kind }
            }
            for source in scoped {
                value.all.rows.append(source)
                value.all.ids.insert(source.id)
                if let kind = kindByID[source.id] {
                    value.verifiedIDs.insert(source.id)
                    value.byKind[kind]?.rows.append(source)
                }
            }
            return value
        }
    }
}

#Preview("订阅源结果页与多选维护") {
    NavigationStack { RSSSourceManagementView(store: RSSStore.shared) }
}
