import SwiftUI
import UniformTypeIdentifiers

private enum ReplaceRulePresentationRoute: Hashable {
    case add
    case importFile
}

// MARK: - List View

/// Manage user-configurable global replace rules.
/// Presented from Settings / Profile.
struct ReplaceRuleListView: View {

    @ObservedObject private var store: ReplaceRuleStore
    @State private var showingAdd = false
    @State private var showingImportFile = false
    @State private var showLegacyActionChooser = false
    @State private var legacyActionSequence =
        DismissalSequencedPresentation<ReplaceRulePresentationRoute>()
    @State private var editingRule: ReplaceRule?
    @State private var selectedImportFile: URL?
    @State private var importError: String?
    @State private var editMode = EditMode.inactive
    @State private var selectedRuleIDs = Set<String>()
    @State private var showBulkDeleteAlert = false
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(store: ReplaceRuleStore = .shared) {
        self.store = store
    }

    private var isSelecting: Bool { editMode == .active }

    private var isAllSelected: Bool {
        !store.rules.isEmpty && store.rules.allSatisfy { selectedRuleIDs.contains($0.id) }
    }

    var body: some View {
        NavigationStack {
            Group {
                if store.rules.isEmpty {
                    VStack(spacing: 16) {
                        Image(systemName: "text.magnifyingglass")
                            .font(DSFont.fixed(size: 48))
                            .foregroundStyle(DSColor.textSecondary)
                        Text(localized("尚無替換規則"))
                            .foregroundStyle(DSColor.textSecondary)
                        Button(localized("新增規則")) { showingAdd = true }
                            .buttonStyle(.bordered)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    // Native multi-select, as the bookshelf: binding the selection Set drives the
                    // system selection circles (and two-finger drag-select) in edit mode.
                    List(selection: $selectedRuleIDs) {
                        ForEach(store.rules) { rule in
                            ReplaceRuleRow(rule: rule, isSelecting: isSelecting, onUpdate: store.update) {
                                editingRule = rule
                            }
                            .tag(rule.id)
                            // Selecting shows the selection circles; without this `.onDelete`
                            // adds its red delete control beside each one. Swipe-to-delete
                            // outside selection is unaffected.
                            .deleteDisabled(isSelecting)
                            .interfaceSectionSurface()
                        }
                        .onDelete { offsets in
                            offsets.map { store.rules[$0].id }.forEach { store.delete(id: $0) }
                        }
                        .onMove { store.move(fromOffsets: $0, toOffset: $1) }
                    }
                    .softScrollEdges()
                    .listStyle(.plain)
                    // `themedAppSurface` below only hides the *list's* background; a `.plain`
                    // row still paints its own opaque `systemBackground` unless handed one.
                    // Same fix as 書源管理 / 語音朗讀設定.
                }
            }
            .navigationTitle(localized("替換規則"))
            .toolbarTitleDisplayMode(.inline)
            .themedAppSurface(for: .settings)
            .toolbar { toolbar }
            // Deleting the last rule while selecting swaps the list for the empty state and
            // hides 編輯; leave selection so the next rule doesn't open in it.
            .onChange(of: store.rules.isEmpty) { _, isEmpty in
                if isEmpty { endSelection() }
            }
            .alert(localized("確認刪除"), isPresented: $showBulkDeleteAlert) {
                Button(localized("刪除"), role: .destructive) {
                    let ids = selectedRuleIDs
                    withAnimation(reduceMotion ? nil : DSAnimation.standard) {
                        store.delete(ids: ids)
                        selectedRuleIDs = []
                    }
                }
                Button(localized("取消"), role: .cancel) {}
            } message: {
                Text(String(format: localized("確定要刪除 %d 條替換規則嗎？"), selectedRuleIDs.count))
            }
            .sheet(
                isPresented: $showLegacyActionChooser,
                onDismiss: presentLegacyActionAfterChooserDismissal
            ) {
                AdaptiveSheetContainer(maxWidth: DSLayout.readableCompactWidth) {
                    DismissalSequencedActionChooser(
                        title: localized("新增或匯入"),
                        actions: [
                            DismissalSequencedAction(
                                route: .add,
                                title: localized("新增規則"),
                                systemImage: "plus"
                            ),
                            DismissalSequencedAction(
                                route: .importFile,
                                title: localized("匯入替換規則 JSON"),
                                systemImage: "square.and.arrow.down"
                            ),
                        ],
                        onSelect: { legacyActionSequence.select($0) }
                    )
                }
            }
            .sheet(isPresented: $showingAdd) {
                ReplaceRuleEditView(rule: nil) { store.add($0) }
            }
            .sheet(item: $editingRule) { rule in
                ReplaceRuleEditView(rule: rule) { store.update($0) }
            }
            .fileImporter(
                isPresented: $showingImportFile,
                allowedContentTypes: [UTType.json, UTType.plainText]
            ) { result in
                switch result {
                case .success(let url): selectedImportFile = url
                case .failure(let error):
                    if (error as? CocoaError)?.code != .userCancelled {
                        importError = localized("無法讀取文件")
                    }
                }
            }
            // 在当前导航栈内推入预览，不在文件选择器关闭时再打开一层弹窗。
            .navigationDestination(item: $selectedImportFile) { url in
                ReplaceRuleImportReviewView(file: url, confirm: store.importConfirmedRules)
            }
            .alert(localized("匯入失敗"), isPresented: Binding(
                get: { importError != nil }, set: { if !$0 { importError = nil } }
            )) {
                Button(localized("完成"), role: .cancel) { importError = nil }
            } message: {
                Text(importError ?? "")
            }
            .interactiveDismissDisabled(selectedImportFile != nil)
            // Outside `.toolbar` so the toolbar's EditButton and the List share one binding.
            .environment(\.editMode, $editMode)
        }
    }

    /// 新增或匯入, 編輯 and done; while selecting, 全選 and done, with delete in a bottom bar —
    /// the bookshelf's selection layout.
    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        if isSelecting {
            // Select-all kept as its own pill via the prominent + clear-tint trick so it
            // doesn't merge with the done button.
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    selectedRuleIDs = isAllSelected ? [] : Set(store.rules.map(\.id))
                } label: {
                    Text(localized(isAllSelected ? "全不選" : "全選"))
                        .font(DSFont.subheadline.weight(.medium))
                        .foregroundStyle(DSColor.textPrimary)
                }
                .buttonStyle(.borderedProminent)
                .tint(.clear)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    endSelection()
                } label: {
                    Image(systemName: "checkmark")
                        .font(DSFont.toolbarIcon)
                }
                .accessibilityLabel(localized("完成"))
            }
            ToolbarItem(placement: .bottomBar) {
                Button(role: .destructive) {
                    if !selectedRuleIDs.isEmpty { showBulkDeleteAlert = true }
                } label: {
                    Image(systemName: "trash")
                }
                .tint(.red)
                .disabled(selectedRuleIDs.isEmpty)
                .accessibilityLabel(localized("刪除"))
            }
        } else {
            ToolbarItem(placement: .topBarLeading) {
                addOrImportToolbarControl
                .accessibilityLabel(localized("新增或匯入"))
            }
            if !store.rules.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(localized("編輯")) {
                        withAnimation(reduceMotion ? nil : DSAnimation.standard) {
                            editMode = .active
                        }
                    }
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "checkmark")
                }
                .accessibilityLabel(localized("完成"))
            }
        }
    }

    private func endSelection() {
        withAnimation(reduceMotion ? nil : DSAnimation.standard) {
            editMode = .inactive
            selectedRuleIDs = []
        }
    }

    @ViewBuilder
    private var addOrImportToolbarControl: some View {
        if MenuModalPresentationPolicy.requiresDismissalSequencedChooser {
            Button {
                legacyActionSequence.cancel()
                showLegacyActionChooser = true
            } label: {
                Image(systemName: "plus")
            }
        } else {
            Menu {
                Button {
                    showingAdd = true
                } label: {
                    Label(localized("新增規則"), systemImage: "plus")
                }

                Button {
                    showingImportFile = true
                } label: {
                    Label(
                        localized("匯入替換規則 JSON"),
                        systemImage: "square.and.arrow.down"
                    )
                }
            } label: {
                Image(systemName: "plus")
            }
        }
    }

    private func presentLegacyActionAfterChooserDismissal() {
        guard let route = legacyActionSequence.consumeAfterDismissal() else {
            return
        }
        switch route {
        case .add:
            showingAdd = true
        case .importFile:
            showingImportFile = true
        }
    }

}

#Preview {
    ReplaceRuleListView(store: .init(
        file: URL.temporaryDirectory.appendingPathComponent("ReplaceRulePreview-\(UUID()).json"),
        rules: [.init(name: "範例", pattern: "example")]
    ))
    .environment(\.usesUserAppearance, false)
}

private struct ReplaceRuleImportReviewView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var review: ReplaceRuleImportReview?
    @State private var failure: String?
    @State private var isSaving = false
    @State private var importedCount: Int?

    let file: URL?
    let confirm: (ReplaceRuleImportReview) async throws -> Int

    init(file: URL? = nil, review: ReplaceRuleImportReview? = nil,
         confirm: @escaping (ReplaceRuleImportReview) async throws -> Int) {
        self.file = file
        _review = State(initialValue: review)
        self.confirm = confirm
    }

    var body: some View {
        Group {
            if let importedCount {
                ContentUnavailableView {
                    Label(localized("成功匯入"), systemImage: "checkmark.circle")
                } description: {
                    Text(String(format: localized("已匯入 %d 條替換規則"), importedCount))
                }
            } else if let review, !review.rows.isEmpty {
                List {
                    Section {
                        Text(String(format: localized("%d 條可匯入，%d 條將略過"), review.rules.count,
                                    review.rows.count - review.rules.count))
                        if let failure { Text(failure).foregroundStyle(DSColor.destructive) }
                    } footer: {
                        if review.hasIssues, !review.rules.isEmpty {
                            Text(localized("確認後只會匯入可支援的規則。")).dsSectionFooter()
                        }
                    }
                    .interfaceSectionSurface()
                    Section {
                        ForEach(review.rows) { row in
                            VStack(alignment: .leading, spacing: DSSpacing.xs) {
                                Text(String(format: localized("第 %d 條規則"), row.id))
                                Text(detail(row.outcome))
                                    .font(DSFont.subheadline)
                                    .foregroundStyle(DSColor.textSecondary)
                            }
                            .accessibilityElement(children: .combine)
                        }
                    }
                    .interfaceSectionSurface()
                }
                .listStyle(.insetGrouped)
            } else if let failure {
                ContentUnavailableView {
                    Label(localized("匯入失敗"), systemImage: "exclamationmark.circle")
                } description: { Text(failure) }
            } else {
                ProgressView(localized("載入中…"))
            }
        }
        .themedAppSurface(for: .settings)
        .navigationTitle(localized("替換規則匯入預覽"))
        .toolbarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden()
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button { dismiss() } label: { Image(systemName: "xmark") }
                    .accessibilityLabel(localized(importedCount == nil ? "取消" : "關閉"))
                    .disabled(isSaving)
            }
            if let review, importedCount == nil, !review.rules.isEmpty {
                ToolbarItem(placement: .confirmationAction) {
                    if isSaving {
                        ProgressView().accessibilityLabel(localized("匯入中，請稍候…"))
                    } else {
                        Button { save(review) } label: { Image(systemName: "checkmark") }
                            .accessibilityLabel(localized("匯入可支援的規則"))
                    }
                }
            }
        }
        .task {
            guard let file, review == nil else { return }
            do {
                let loaded = try await ReplaceRuleImportParser.review(file: file)
                try Task.checkCancellation()
                guard !loaded.rows.isEmpty else { throw ReplaceRuleImportError.noRules }
                review = loaded
            } catch is CancellationError {
                return // 退出预览不写盘，也不显示错误。
            } catch {
                failure = error.localizedDescription
            }
        }
    }

    private func detail(_ outcome: ReplaceRuleImportReview.Row.Outcome) -> String {
        switch outcome {
        case .supported(let rule, _):
            return rule.name.isEmpty ? localized("可匯入") :
                String(format: localized("可匯入：%@"), String(rule.name.prefix(256)))
        case .unsupported(let fields):
            return String(format: localized("不支援的欄位：%@"), fields.joined(separator: ", "))
        case .invalid(let fields):
            return fields.isEmpty ? localized("規則格式無效") :
                String(format: localized("無效的欄位：%@"), fields.joined(separator: ", "))
        }
    }

    private func save(_ review: ReplaceRuleImportReview) {
        guard !isSaving else { return }
        isSaving = true
        failure = nil
        Task {
            defer { isSaving = false }
            do { importedCount = try await confirm(review) }
            catch {
                failure = (error as? ReplaceRuleImportError)?.localizedDescription ?? localized("替換規則儲存失敗，請再試一次。")
            }
        }
    }
}

#Preview("替換規則匯入預覽") {
    NavigationStack {
        ReplaceRuleImportReviewView(review: .init(rows: [
            .init(id: 1, outcome: .supported(.init(name: "範例", pattern: "example"), originalID: nil)),
            .init(id: 2, outcome: .unsupported(["excludeScope"])),
            .init(id: 3, outcome: .invalid(["scopeContent"]))
        ])) { $0.rules.count }
    }
    .environment(\.usesUserAppearance, false)
}

// MARK: - Row

private struct ReplaceRuleRow: View {

    let rule: ReplaceRule
    let isSelecting: Bool
    let onUpdate: (ReplaceRule) -> Void
    let onTap: () -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(rule.name.isEmpty ? localized("未命名規則") : rule.name)
                        .font(DSFont.subheadline)
                        .bold()
                        .foregroundColor(rule.enabled ? .primary : .secondary)

                    if rule.scope != "global" {
                        Text(localized("來源配置"))
                            .font(DSFont.caption2)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(DSColor.highlight)
                            .foregroundColor(DSColor.accent)
                            .cornerRadius(3)
                    }
                    if rule.isRegex {
                        Text("Regex")
                            .font(DSFont.caption2)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Color.purple.opacity(0.12))
                            .foregroundColor(.purple)
                            .cornerRadius(3)
                    }
                }
                Text(rule.pattern)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(DSColor.textSecondary)
                    .lineLimit(1)
                if !rule.replacement.isEmpty {
                    Text("→ \(rule.replacement)")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundColor(.green)
                        .lineLimit(1)
                }
            }
            Spacer()
            Toggle("", isOn: Binding(
                get: { rule.enabled },
                set: { var updated = rule; updated.enabled = $0; onUpdate(updated) }
            ))
            .labelsHidden()
        }
        .contentShape(Rectangle())
        // While selecting, a tap belongs to the List's selection, not the editor; the toggle
        // (a subview) stays live either way.
        .gesture(TapGesture().onEnded { onTap() }, including: isSelecting ? .subviews : .all)
    }
}

// MARK: - Edit View

struct ReplaceRuleEditView: View {

    @State private var rule: ReplaceRule
    let onSave: (ReplaceRule) -> Void
    @Environment(\.dismiss) private var dismiss

    init(rule: ReplaceRule?, onSave: @escaping (ReplaceRule) -> Void) {
        _rule = State(initialValue: rule ?? ReplaceRule(name: "", pattern: ""))
        self.onSave = onSave
    }

    var body: some View {
        NavigationStack {
            Form {
                Section(header: Text(localized("基本")).foregroundStyle(DSColor.textSecondary)) {
                    TextField(localized("規則名稱"), text: $rule.name)
                    Toggle(localized("啟用"), isOn: $rule.enabled)
                }
                .interfaceSectionSurface()

                Section(header: Text(localized("匹配")).foregroundStyle(DSColor.textSecondary)) {
                    Toggle(localized("正則表達式"), isOn: $rule.isRegex)
                    TextField(localized("匹配模式"), text: $rule.pattern)
                        .font(DSFont.fixed(size: 14, design: .monospaced))
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                    TextField(localized("替換為（空白=刪除）"), text: $rule.replacement)
                        .font(DSFont.fixed(size: 14, design: .monospaced))
                        .autocapitalization(.none)
                }
                .interfaceSectionSurface()

                Section(header: Text(localized("作用範圍")).foregroundStyle(DSColor.textSecondary)) {
                    Picker(localized("範圍"), selection: $rule.scope) {
                        Text(localized("全局")).tag("global")
                        if rule.scope != "global" {
                            Text(rule.scope).tag(rule.scope)
                        }
                    }
                    .pickerStyle(.inline)
                }
                .interfaceSectionSurface()
            }
            .softScrollEdges()
            .navigationTitle(rule.name.isEmpty ? localized("新增規則") : rule.name)
            .toolbarTitleDisplayMode(.inline)
            .themedAppSurface(for: .settings)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        onSave(rule)
                        dismiss()
                    } label: {
                        Image(systemName: "checkmark")
                    }
                    .disabled(rule.pattern.isEmpty)
                }
            }
        }
    }
}

#Preview("替換規則編輯") {
    ReplaceRuleEditView(rule: .init(name: "範例", pattern: "example")) { _ in }
        .environment(\.usesUserAppearance, false)
}
