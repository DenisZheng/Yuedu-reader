import SwiftUI

struct RuleSubscriptionListView: View {
    @State private var store: RuleSubscriptionStore
    @State private var editing: RuleSubscription?
    @State private var review: Review?
    @State private var deleting: RuleSubscription?
    @State private var message: String?
    private struct Review: Identifiable {
        let id: UUID
        let name: String
        let plan: RuleSubscriptionUpdatePlan
    }

    init(store: RuleSubscriptionStore = .shared) { _store = State(initialValue: store) }

    var body: some View {
        List {
            Section {
                if !store.isLoaded {
                    if let failure = store.failureMessage {
                        Text(failure).foregroundStyle(DSColor.destructive)
                        Button(localized("重試")) { Task { await load() } }
                    } else { ProgressView(localized("載入中…")) }
                } else if store.subscriptions.isEmpty {
                    ContentUnavailableView(localized("尚無規則包訂閱"), systemImage: "arrow.triangle.2.circlepath",
                        description: Text(localized("新增配置包網址，之後可檢查書源、RSS或替換規則更新。")))
                } else {
                    ForEach(store.subscriptions) { subscription in
                        RuleSubscriptionRow(subscription: subscription, outcome: store.outcomes[subscription.id],
                            onEdit: { editing = subscription },
                            onCheck: { Task { await store.check(subscription.id) } },
                            onReview: {
                                if let plan = store.pending[subscription.id] {
                                    review = Review(id: subscription.id, name: subscription.name, plan: plan)
                                }
                            }, onCancel: { store.cancel(subscription.id) })
                        .swipeActions {
                            Button(role: .destructive) { deleting = subscription } label: { Label(localized("刪除"), systemImage: "trash") }
                        }
                    }
                }
                if let message { Text(message).foregroundStyle(DSColor.destructive) }
            } footer: {
                Text(localized("這裡更新來源配置包，不抓取RSS文章；自動更新只在App前台檢查到期項目。"))
                    .dsSectionFooter()
            }
            .interfaceSectionSurface()
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(PageBackgroundView(scope: .settings).ignoresSafeArea())
        .pageBackgroundToolbar(for: .settings)
        .navigationTitle(localized("規則包訂閱"))
        .toolbarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { editing = RuleSubscription(name: "", url: "") } label: {
                    Label(localized("新增規則包訂閱"), systemImage: "plus").labelStyle(.iconOnly)
                }
                .disabled(!store.isLoaded)
                .accessibilityIdentifier("ruleSubscription.add")
            }
        }
        .sheet(item: $editing) { value in
            NavigationStack { RuleSubscriptionEditorView(value: value) { try await store.upsert($0) } }
        }
        .sheet(item: $review) { value in
            NavigationStack {
                RuleSubscriptionReviewView(name: value.name, plan: value.plan, onCancel: { store.cancel(value.id) }) {
                    await store.confirm(value.id)
                    switch store.outcomes[value.id] {
                    case .updated, .upToDate: return nil
                    default: return store.outcomes[value.id]?.message ?? localized("更新已取消")
                    }
                }
            }
        }
        .alert(localized("刪除規則包訂閱？"), isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button(localized("取消"), role: .cancel) { deleting = nil }
            Button(localized("刪除"), role: .destructive) {
                guard let value = deleting else { return }
                deleting = nil
                Task {
                    do { try await store.delete(value.id) }
                    catch { message = localized("規則訂閱操作失敗，請重試") }
                }
            }
        } message: { Text(localized("只刪除更新訂閱，已匯入的來源配置不會被刪除。")) }
        .task { await load() }
        .accessibilityIdentifier("ruleSubscription.list")
    }
    private func load() async {
        do { try await store.load(); message = nil }
        catch { message = store.failureMessage ?? localized("規則訂閱操作失敗，請重試") }
    }
}

private struct RuleSubscriptionRow: View {
    let subscription: RuleSubscription
    let outcome: RuleSubscriptionStore.Outcome?
    let onEdit: () -> Void
    let onCheck: () -> Void
    let onReview: () -> Void
    let onCancel: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: DSSpacing.sm) {
            Button(action: onEdit) {
                VStack(alignment: .leading, spacing: DSSpacing.xs) {
                    Text(subscription.name).font(DSFont.headline)
                    Text(subscription.type.title).font(DSFont.caption).foregroundStyle(DSColor.textSecondary)
                }
            }.buttonStyle(.borderless)
            if let outcome { Text(outcome.message).font(DSFont.caption).foregroundStyle(DSColor.textSecondary) }
            if let time = subscription.lastSuccessfulCheck {
                LabeledContent(localized("上次成功檢查"), value: Date(timeIntervalSince1970: Double(time) / 1_000).formatted())
                    .font(DSFont.caption).foregroundStyle(DSColor.textSecondary)
            }
            HStack {
                if outcome == .checking {
                    ProgressView()
                    Button(localized("取消"), action: onCancel)
                } else {
                    Button(localized("檢查更新"), action: onCheck)
                    if case .pending = outcome { Button(localized("確認更新"), action: onReview) }
                }
            }.buttonStyle(.borderless)
        }
    }
}

struct RuleSubscriptionEditorView: View {
    @State private var draft: RuleSubscription
    @State private var saving = false
    @State private var message: String?
    @Environment(\.dismiss) private var dismiss
    let onSave: (RuleSubscription) async throws -> Void
    init(value: RuleSubscription, onSave: @escaping (RuleSubscription) async throws -> Void) {
        _draft = State(initialValue: value); self.onSave = onSave
    }
    var body: some View {
        Form {
            Section {
                TextField(localized("名稱"), text: $draft.name)
                TextField(localized("網址"), text: $draft.url)
                    .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                Picker(localized("配置包類型"), selection: $draft.type) {
                    ForEach(RuleSubscription.Kind.allCases) { kind in Text(kind.title).tag(kind) }
                }
            }.interfaceSectionSurface()
            Section {
                Toggle(isOn: $draft.autoUpdate) { SettingsRowLabel(localized("自動檢查更新"), systemImage: "arrow.clockwise") }
                Stepper(value: $draft.updateInterval, in: 0...8_760) {
                    SettingsRowLabel(String(format: localized("更新間隔：%d 小時"), draft.updateInterval), systemImage: "clock")
                }
                Toggle(isOn: $draft.silentUpdate) { SettingsRowLabel(localized("靜默更新"), systemImage: "square.and.arrow.down") }
            } footer: {
                Text(localized("靜默更新會修改本地配置，保留已有名稱、分組和啟用狀態；關閉後先確認。"))
                    .dsSectionFooter()
            }.interfaceSectionSurface()
            if let message { Section { Text(message).foregroundStyle(DSColor.destructive) }.interfaceSectionSurface() }
        }
        .scrollContentBackground(.hidden)
        .background(PageBackgroundView(scope: .settings).ignoresSafeArea())
        .pageBackgroundToolbar(for: .settings)
        .navigationTitle(localized("編輯規則包訂閱"))
        .toolbarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button { dismiss() } label: { Label(localized("取消"), systemImage: "xmark").labelStyle(.iconOnly) }
                    .disabled(saving)
            }
            ToolbarItem(placement: .confirmationAction) {
                Button {
                    saving = true
                    Task {
                        do { try await onSave(draft); dismiss() }
                        catch { message = (error as? RuleSubscriptionFailure)?.localizedDescription ?? localized("規則訂閱操作失敗，請重試") }
                        saving = false
                    }
                } label: { Label(localized("儲存"), systemImage: "checkmark").labelStyle(.iconOnly) }
                .disabled(saving || (try? draft.validated()) == nil)
            }
        }
    }
}

private struct RuleSubscriptionReviewView: View {
    let name: String
    let plan: RuleSubscriptionUpdatePlan
    let onCancel: () -> Void
    let onConfirm: () async -> String?
    @State private var saving = false
    @State private var message: String?
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        List {
            Section {
                ForEach(plan.entries) { entry in Text(entry.title) }
            } header: { Text(String(format: localized("更新 %d 項配置"), plan.count)) }
            .interfaceSectionSurface()
            if saving { ProgressView(localized("正在儲存更新…")) }
            if let message { Text(message).foregroundStyle(DSColor.destructive) }
        }
        .scrollContentBackground(.hidden)
        .background(PageBackgroundView(scope: .settings).ignoresSafeArea())
        .pageBackgroundToolbar(for: .settings)
        .navigationTitle(String(name.prefix(256)))
        .toolbarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button { onCancel(); dismiss() } label: { Label(localized("取消"), systemImage: "xmark").labelStyle(.iconOnly) }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button {
                    saving = true
                    Task { message = await onConfirm(); saving = false; if message == nil { dismiss() } }
                } label: { Label(localized("確認更新"), systemImage: "checkmark").labelStyle(.iconOnly) }
                .disabled(saving || message != nil)
            }
        }
    }
}

#Preview("规则包订阅") { NavigationStack { RuleSubscriptionListView() } }
#Preview("规则包编辑") {
    NavigationStack { RuleSubscriptionEditorView(value: RuleSubscription(name: "合成配置包", url: "https://example.invalid/sources.json")) { _ in } }
}
