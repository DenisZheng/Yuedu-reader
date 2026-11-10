import SwiftUI

/// 订阅源设置（对齐 Legado RssSourceEditActivity 的必要能力）：开关、Legado JSON 规则编辑、
/// 登录、源变量与可视化调试。所有写入走 RSSStore，配置修订会让旧请求失效。
struct RSSSourceSettingsView: View {
    let sourceID: String
    @ObservedObject var store: RSSStore
    @State private var debugger = RSSSourceDebugger()
    @State private var debugKey = ""
    @State private var variableText = ""
    @State private var variableError: String?
    @State private var savedVariable: String?
    @State private var savingVariable = false

    private var source: RSSSource? { store.source(id: sourceID) }

    var body: some View {
        Group {
            if let source {
                form(source)
            } else {
                ContentUnavailableView(localized("訂閱已刪除"), systemImage: "trash")
            }
        }
        .navigationTitle(localized("來源設定"))
        .toolbarTitleDisplayMode(.inline)
        .themedAppSurface(for: .rss)
        .onDisappear { debugger.cancel() }
    }

    private func form(_ source: RSSSource) -> some View {
        Form {
            Section {
                toggle(localized("啟用"), \.enabled, source, id: "rss.settings.enabled")
                toggle(localized("執行 JavaScript"), \.enableJs, source, id: "rss.settings.enableJs")
                toggle(localized("啟用 CookieJar"), \.enabledCookieJar, source, id: "rss.settings.cookieJar")
                toggle(localized("以 baseURL 載入"), \.loadWithBaseUrl, source, id: "rss.settings.baseURL")
                toggle(localized("單一網址"), \.singleUrl, source, id: "rss.settings.singleUrl")
                optionalToggle(localized("優先使用快取"), \.cacheFirst, source, id: "rss.settings.cacheFirst")
                optionalToggle(localized("顯示網頁日誌"), \.showWebLog, source, id: "rss.settings.webLog")
            } header: {
                Text(localized("行為")).foregroundStyle(DSColor.textSecondary)
            }
            .interfaceSectionSurface()

            Section {
                NavigationLink {
                    RSSSourceJSONEditor(sourceID: sourceID, store: store)
                } label: {
                    Label(localized("規則（Legado JSON）"), systemImage: "curlybraces")
                }
                .accessibilityIdentifier("rss.settings.json")
                if source.loginUrl?.isEmpty == false || source.loginUi?.isEmpty == false {
                    NavigationLink {
                        RSSSourceLoginView(source: source, owner: store)
                    } label: {
                        Label(localized("登入"), systemImage: "person.badge.key")
                    }
                    .accessibilityIdentifier("rss.settings.login")
                }
            } header: {
                Text(localized("規則")).foregroundStyle(DSColor.textSecondary)
            }
            .interfaceSectionSurface()

            Section {
                TextField(localized("來源變數"), text: $variableText, axis: .vertical)
                    .lineLimit(3...8)
                    .font(DSFont.body.monospaced())
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("rss.settings.variable")
                Button(localized("儲存變數")) { Task { await saveVariable(source) } }
                    .disabled(savedVariable == nil || savingVariable || variableText == savedVariable)
                if let variableError { Text(variableError).font(DSFont.footnote).foregroundStyle(.red) }
            } header: {
                Text(localized("來源變數")).foregroundStyle(DSColor.textSecondary)
            } footer: {
                if let comment = source.variableComment, !comment.isEmpty {
                    Text(comment).dsSectionFooter()
                }
            }
            .interfaceSectionSurface()

            Section {
                TextField(localized("留空＝第一個分類；分類名::網址；網址＝正文；其他＝搜尋"), text: $debugKey)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("rss.settings.debugKey")
                if debugger.isRunning {
                    Button(localized("停止"), role: .destructive) { debugger.cancel() }
                } else {
                    Button(localized("開始除錯")) { debugger.start(source: source, key: debugKey, owner: store) }
                        .disabled(!source.isLegadoRuleBased)
                        .accessibilityIdentifier("rss.settings.debugStart")
                }
                ForEach(debugger.lines) { line in
                    Label { Text(line.text).font(DSFont.footnote).textSelection(.enabled) } icon: { icon(line.level) }
                        .accessibilityIdentifier("rss.settings.debugLine")
                }
            } header: {
                Text(localized("除錯")).foregroundStyle(DSColor.textSecondary)
            } footer: {
                Text(localized("網址只顯示到路徑，不顯示查詢參數、正文或錯誤原文。")).dsSectionFooter()
            }
            .interfaceSectionSurface()
        }
        .softScrollEdges()
        .task(id: sourceID) {
            do {
                let value = try store.runtimeSnapshot(for: source).variableJSON ?? ""
                variableText = value
                savedVariable = value
                variableError = nil
            } catch {
                savedVariable = nil
                variableError = RSSSourceDebugger.describe(error)
            }
        }
    }

    private func toggle(_ title: String, _ key: WritableKeyPath<RSSSource, Bool>, _ source: RSSSource, id: String) -> some View {
        Toggle(title, isOn: Binding(get: { source[keyPath: key] }, set: { value in
            guard var current = store.source(id: sourceID) else { return }
            current[keyPath: key] = value
            store.updateSource(current)
        }))
        .accessibilityIdentifier(id)
    }

    private func optionalToggle(_ title: String, _ key: WritableKeyPath<RSSSource, Bool?>, _ source: RSSSource, id: String) -> some View {
        Toggle(title, isOn: Binding(get: { source[keyPath: key] == true }, set: { value in
            guard var current = store.source(id: sourceID) else { return }
            current[keyPath: key] = value
            store.updateSource(current)
        }))
        .accessibilityIdentifier(id)
    }

    @ViewBuilder private func icon(_ level: RSSSourceDebugger.Line.Level) -> some View {
        switch level {
        case .step: Image(systemName: "arrow.down.circle").foregroundStyle(DSColor.accent)
        case .info: Image(systemName: "circle.fill").font(DSFont.caption2).foregroundStyle(DSColor.textSecondary)
        case .success: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failure: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        }
    }

    private func saveVariable(_ source: RSSSource) async {
        savingVariable = true
        defer { savingVariable = false }
        do {
            try store.setSourceVariableJSON(variableText, for: source.id)
            try await store.retryPersistence()
            savedVariable = variableText
            variableError = nil
        } catch { variableError = localized("RSS 執行狀態無法讀取，已停止執行來源") }
    }
}

/// 以 Legado JSON 编辑单个源的全部字段；保存前用导入同一解析器验证，保留本地身份和本地状态字段。
struct RSSSourceJSONEditor: View {
    let sourceID: String
    @ObservedObject var store: RSSStore
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var error: String?
    @State private var loaded = false
    @State private var working = false
    @State private var baseline: RSSSource?

    var body: some View {
        TextEditor(text: $text)
            .font(DSFont.footnote.monospaced())
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .padding(.horizontal, DSSpacing.sm)
            .accessibilityLabel(localized("規則（Legado JSON）"))
            .accessibilityIdentifier("rss.settings.jsonText")
            .safeAreaInset(edge: .bottom) {
                if let error {
                    Text(error).font(DSFont.footnote).foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(DSSpacing.md).background(DSColor.surface)
                        .accessibilityIdentifier("rss.settings.jsonError")
                }
            }
            .navigationTitle(localized("規則（Legado JSON）"))
            .toolbarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { Task { await save() } } label: { Label(localized("儲存"), systemImage: "checkmark").labelStyle(.iconOnly) }
                        .disabled(!loaded || working)
                        .accessibilityIdentifier("rss.settings.jsonSave")
                }
            }
            .task { await load() }
            .disabled(working)
    }

    private func load() async {
        guard !loaded, let source = store.source(id: sourceID) else { return }
        working = true
        defer { working = false }
        do {
            text = try await SourceScriptThread.run {
                try SourcePerfTrace.span("rss.source.edit.encode", "main=\(Thread.isMainThread)") {
                    let data = try JSONSerialization.data(withJSONObject: LegadoSourceJSONParser.exportJSON(from: source),
                                                          options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
                    return String(decoding: data, as: UTF8.self)
                }
            }
            try Task.checkCancellation()
            baseline = source
            loaded = true
        } catch {
            self.error = localized("無法匯出此來源")
        }
    }

    private func save() async {
        guard let baseline, store.source(id: sourceID) == baseline else {
            error = RSSImportService.Issue.stalePlan.localizedDescription
            return
        }
        working = true
        defer { working = false }
        let draft = text, others = store.sources, revision = store.configurationRevision
        do {
            let edited = try await SourceScriptThread.run {
                try RSSSourceJSONEditor.apply(draft, to: baseline, others: others)
            }
            try Task.checkCancellation()
            guard store.configurationRevision == revision else { throw RSSImportService.Issue.stalePlan }
            store.updateSource(edited)
            self.baseline = edited
            try await store.retryPersistence()
            dismiss()
        } catch let failure as RSSSourceEditFailure {
            self.error = failure.message
        } catch let failure as RSSImportService.Issue {
            self.error = failure.localizedDescription
        } catch {
            self.error = localized("規則 JSON 無效")
        }
    }

    /// 纯函数便于测试：解析同导入；保留 id、排序、本地 Feed 元数据与通知开关。
    nonisolated static func apply(_ text: String, to current: RSSSource, others: [RSSSource]) throws -> RSSSource {
        let object: [String: Any]
        do {
            guard let data = text.data(using: .utf8), let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw RSSSourceEditFailure(message: localized("規則 JSON 無效"))
            }
            object = value
        } catch let failure as RSSSourceEditFailure { throw failure }
        catch { throw RSSSourceEditFailure(message: localized("規則 JSON 無效")) }
        var parsed: RSSSource
        do { parsed = try LegadoSourceJSONParser.parseSource(from: object) }
        catch { throw RSSSourceEditFailure(message: localized("規則 JSON 無效")) }
        if parsed.url != current.url, others.contains(where: { $0.id != current.id && $0.url == parsed.url }) {
            throw RSSSourceEditFailure(message: localized("此網址已被其他訂閱使用"))
        }
        parsed.id = current.id
        parsed.sortOrder = current.sortOrder
        parsed.newArticleNotificationsEnabled = current.newArticleNotificationsEnabled
        parsed.importedFromLegado = current.importedFromLegado ?? true
        if parsed.url == current.url {
            parsed.homepageURL = current.homepageURL
            parsed.resolvedFeedURL = current.resolvedFeedURL
        }
        return parsed
    }
}

struct RSSSourceEditFailure: Error { let message: String }

#Preview("RSS source settings") {
    let store = RSSStore(storageDirectory: URL.temporaryDirectory.appendingPathComponent("rss-settings-preview"))
    var source = RSSSource(name: "Preview", url: "https://example.invalid/rss")
    source.ruleArticles = "class.item"; source.loginUrl = "https://example.invalid/login"
    return NavigationStack { RSSSourceSettingsView(sourceID: source.id, store: store) }
        .onAppear { _ = store.addSourcesReturningAdded([source]) }
}
