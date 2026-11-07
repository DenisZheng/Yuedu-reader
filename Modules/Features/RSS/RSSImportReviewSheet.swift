import SwiftUI

struct RSSImportReviewRequest: Identifiable {
    let id = UUID()
    var input: RSSImportService.Input
}

struct RSSImportReviewSheet: View {
    let input: RSSImportService.Input
    @State private var session: RSSImportSession
    @Environment(\.dismiss) private var dismiss

    init(input: RSSImportService.Input, store: RSSStore) {
        self.input = input
        _session = State(initialValue: RSSImportSession(store: store))
    }

    var body: some View {
        NavigationStack {
            Form {
                switch session.phase {
                case .loading:
                    ProgressView(localized("正在讀取訂閱配置…"))
                case .review:
                    reviewSections
                case .saving:
                    ProgressView(localized("正在儲存訂閱配置…"))
                case .saved:
                    savedSection
                case .saveFailed:
                    Text(session.message ?? RSSImportService.Issue.persistence.message)
                        .accessibilityIdentifier("rss-import-error")
                    Button(localized("重試儲存")) { session.retrySave() }
                case .failed:
                    ContentUnavailableView(localized("無法匯入"), systemImage: "exclamationmark.triangle",
                                           description: Text(session.message ?? ""))
                }
            }
            .navigationTitle(localized("匯入 Legado JSON"))
            .toolbarTitleDisplayMode(.inline)
            .themedAppSurface(for: .rss)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { session.cancel(); dismiss() } label: {
                        Label(localized("關閉"), systemImage: "xmark").labelStyle(.iconOnly)
                    }
                    .accessibilityIdentifier("rss-import-close")
                }
                if session.phase == .review {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { session.confirm() } label: {
                            Label(localized("確認匯入"), systemImage: "checkmark").labelStyle(.iconOnly)
                        }
                        .disabled(session.selected.isEmpty)
                        .accessibilityIdentifier("rss-import-confirm")
                    }
                }
            }
            .task { await session.load(input) }
            .onDisappear { session.cancel() }
        }
    }

    @ViewBuilder private var reviewSections: some View {
        if let message = session.message {
            Section {
                Text(message).accessibilityIdentifier("rss-import-error")
                Button(localized("重新比較")) { session.recompare() }
            }.interfaceSectionSurface()
        }
        if let plan = session.plan {
            Section {
                Text(String(format: localized("新增 %d、更新 %d、跳過 %d、錯誤 %d"),
                            plan.additions, plan.updates, plan.skips, plan.errors))
                    .accessibilityIdentifier("rss-import-summary")
            } footer: {
                Text(localized("更新保留本地名稱、分組、啟用狀態、排序與通知設定；儲存後可另行刷新。"))
                    .dsSectionFooter()
            }.interfaceSectionSurface()
            if plan.rows.isEmpty {
                ContentUnavailableView(localized("沒有可匯入的訂閱源"), systemImage: "tray")
            }
            Section {
                ForEach(plan.rows) { row in
                    if row.disposition.selectable {
                        Toggle(isOn: Binding(get: { session.selected.contains(row.id) }, set: {
                            if $0 { session.selected.insert(row.id) } else { session.selected.remove(row.id) }
                        })) { RSSImportRowLabel(row: row) }
                    } else {
                        RSSImportRowLabel(row: row)
                    }
                }
            }.interfaceSectionSurface()
        }
    }

    private var savedSection: some View {
        Section {
            Text(session.message ?? "").accessibilityIdentifier("rss-import-result")
            if let refreshMessage = session.refreshMessage { Text(refreshMessage) }
            if session.isRefreshing {
                ProgressView(localized("正在刷新訂閱…"))
                Button(localized("取消刷新")) { session.cancelRefresh() }
            } else {
                Button(localized("刷新已匯入訂閱")) { session.refresh() }
                    .accessibilityIdentifier("rss-import-refresh")
            }
        } footer: {
            Text(localized("導入保真不代表源可用；刷新可能執行源規則，但不會自動開啟登入網頁。"))
                .dsSectionFooter()
        }.interfaceSectionSurface()
    }
}

private struct RSSImportRowLabel: View {
    let row: RSSImportService.Row
    var body: some View {
        VStack(alignment: .leading, spacing: DSSpacing.xs) {
            Text(row.source?.name ?? String(format: localized("項目 %@"), row.location))
            Text(row.issue?.message ?? row.disposition.label)
                .font(DSFont.subheadline).foregroundStyle(DSColor.textSecondary)
            if row.changedFields > 0 {
                Text(String(format: localized("%d 個配置欄位變更"), row.changedFields))
                    .font(DSFont.footnote).foregroundStyle(DSColor.textSecondary)
            }
            if row.unknownFields > 0 {
                Text(String(format: localized("保留 %d 個未識別欄位，尚未執行"), row.unknownFields))
                    .font(DSFont.footnote).foregroundStyle(DSColor.textSecondary)
            }
        }
    }
}

#Preview("RSS import comparison") {
    Form {
        RSSImportRowLabel(row: .init(id: UUID(), source: RSSSource(name: "Example", url: "opaque"),
                                    disposition: .update, location: "1", changedFields: 3, unknownFields: 1))
        RSSImportRowLabel(row: .init(id: UUID(), disposition: .invalid, issue: .invalidFormat, location: "2"))
    }
}
