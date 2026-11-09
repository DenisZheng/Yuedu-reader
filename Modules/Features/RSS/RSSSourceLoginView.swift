import SwiftUI

/// RSS登录是源自己的前台操作；正文enableJs不关闭网站登录必需的JavaScript，且不把源桥暴露给登录网站。
struct RSSSourceLoginView: View {
    let source: RSSSource
    let owner: RSSStore
    @Environment(\.dismiss) private var dismiss
    @State private var fields: [LoginField] = []
    @State private var labels: [String: String] = [:]
    @State private var values: [String: String] = [:]
    @State private var webTarget: RSSOpenTarget?
    @State private var webError: String?
    @State private var webLoading = true
    @State private var authBridge = RSSWebAuthenticationBridge()
    @State private var router = RSSWebActionRouter()
    @State private var isLoading = true
    @State private var error: String?
    @State private var reloadID = UUID()
    @State private var work: Task<Void, Never>?
    @State private var isVisible = false
    @State private var canLogin = false
    @State private var interactions = RSSLoginInteractionState()

    private var interactionHandlers: SourceUserInterfaceHandlers {
        SourceUserInterfaceHandlers(
            browser: { runtime, request, completion in
                Task { @MainActor in interactions.present(request, runtime: runtime, completion: completion) }
            },
            captcha: { _, request, completion in
                Task { @MainActor in interactions.present(request, completion: completion) }
            },
            browserPage: { runtime, request in
                Task { @MainActor in interactions.present(request, source: runtime.source, runtime: runtime) }
            }
        )
    }

    var body: some View {
        Group {
            if let webTarget {
                RSSSourcePageWebView(source: source, target: webTarget, error: $webError, loading: $webLoading,
                                     owner: owner, isActive: isVisible, authentication: true, authenticationBridge: authBridge)
                    .overlay(alignment: .top) {
                        if webLoading { ProgressView().padding(DSSpacing.md) }
                        if let webError { Text(webError).font(DSFont.footnote).padding(DSSpacing.md).background(DSColor.surface) }
                    }
            } else {
                Form {
                    if isLoading { ProgressView().accessibilityLabel(localized("載入中")) }
                    else if fields.isEmpty && error == nil { ContentUnavailableView(localized("沒有登入欄位"), systemImage: "person.crop.circle") }
                    Section {
                        ForEach(fields) { field in row(field) }
                    }
                    .listRowBackground(DSColor.surface)
                    if !fields.contains(where: { $0.type == .button }), canLogin {
                        Section { Button(localized("登入")) { perform(login: true) }.accessibilityIdentifier("rss.login.submit") }
                            .listRowBackground(DSColor.surface)
                    }
                    if let error {
                        Section {
                            Text(error).foregroundStyle(DSColor.destructive)
                            Button(localized("重試")) { reloadID = UUID() }
                        }
                        .listRowBackground(DSColor.surface)
                    }
                }
                .scrollContentBackground(.hidden)
                .background(DSColor.groupedBackground)
                .disabled(isLoading)
            }
        }
        .navigationTitle(String(format: localized("登入：%@"), source.name))
        .toolbarTitleDisplayMode(.inline)
        .hidesRootTabBar()
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    if webTarget != nil { finishBrowser() } else { perform(closes: true) }
                } label: { Image(systemName: "checkmark") }
                .accessibilityLabel(localized("完成"))
                .accessibilityIdentifier("rss.login.done")
                .disabled(isLoading || webTarget != nil && webLoading)
            }
        }
        .modifier(RSSWebActionPresentation(router: router, owner: owner))
        .sheet(item: $interactions.browser) { page in
            RSSLoginBrowserSheet(source: source, owner: owner, page: page, state: interactions)
        }
        .sheet(item: $interactions.captcha) { captcha in
            SourceCaptchaView(request: captcha.request) { interactions.finishCaptcha($0) }
        }
        .overlay(alignment: .top) {
            if let message = interactions.error { Text(message).font(DSFont.footnote).padding(DSSpacing.md).background(DSColor.surface) }
        }
        .task(id: reloadID) { await load() }
        .onAppear { isVisible = true }
        .onDisappear { isVisible = false; work?.cancel(); work = nil; interactions.cancel() }
    }
    @ViewBuilder private func row(_ field: LoginField) -> some View {
        let title = labels[field.name] ?? field.name
        switch field.type {
        case .text:
            TextField(title, text: binding(field)).textInputAutocapitalization(.never).autocorrectionDisabled()
                .accessibilityIdentifier("rss.login.field." + field.name)
        case .password:
            SecureField(title, text: binding(field)).textContentType(.password)
                .accessibilityIdentifier("rss.login.field." + field.name)
        case .select:
            if field.options.isEmpty { TextField(title, text: binding(field)) }
            else {
                Picker(title, selection: binding(field, performsAction: true)) {
                    ForEach(field.options, id: \.self) { Text($0).tag($0) }
                }
            }
        case .toggle:
            if let chars = LoginToggleChars(options: field.options) {
                Toggle(title, isOn: Binding(get: { chars.isOn(stored: values[field.name], default: field.defaultValue) }, set: {
                    values[field.name] = $0 ? chars.on : chars.off
                    if field.action != nil { perform(action: field.action) }
                }))
            } else { TextField(title, text: binding(field)) }
        case .button:
            Button(title) { perform(action: field.action) }
                .accessibilityIdentifier("rss.login.action." + field.name)
        }
    }
    private func binding(_ field: LoginField, performsAction: Bool = false) -> Binding<String> {
        Binding(get: { values[field.name] ?? field.defaultValue ?? "" }, set: {
            values[field.name] = $0
            if performsAction, field.action != nil { perform(action: field.action) }
        })
    }
    @MainActor private func load() async {
        let id = reloadID
        isLoading = true; error = nil
        defer { if id == reloadID { isLoading = false } }
        do {
            let snapshot = try await RSSLoginService.load(source: source, owner: owner, interactions: interactionHandlers)
            try Task.checkCancellation()
            guard id == reloadID else { return }
            fields = snapshot.fields; labels = snapshot.labels; values = snapshot.values; webTarget = snapshot.webTarget; canLogin = snapshot.canLogin
        } catch is CancellationError { return }
        catch { self.error = message(error) }
    }
    private func perform(action: String? = nil, login: Bool = false, closes: Bool = false) {
        guard !isLoading else { return }
        isLoading = true; error = nil
        work = Task {
            defer { isLoading = false; work = nil }
            do {
                let result = try await RSSLoginService.perform(source: source, owner: owner, values: values, action: action, login: login, interactions: interactionHandlers)
                try Task.checkCancellation()
                if let target = result.webTarget { webTarget = target; return }
                for action in result.actions {
                    guard let ticket = owner.requestTicket(for: source.id) else { throw CancellationError() }
                    try router.receive(.init(action: action, authority: .sourceRule, sourceID: source.id, ownerID: owner.runtimeIdentity,
                        ticket: ticket, baseURL: source.articleLinkBaseURL,
                        credentialRevision: LoginManager.shared.loginInfoRevision(sourceUrl: RSSRuntime.authenticationKey(for: source))), source: source, owner: owner)
                }
                if closes || login { owner.authenticationChanged(for: source.id); dismiss() }
                else if result.actions.isEmpty { reloadID = UUID() }
            } catch is CancellationError { return }
            catch { self.error = message(error) }
        }
    }
    private func finishBrowser() {
        guard !isLoading, let finish = authBridge.finish else { return }
        isLoading = true
        work = Task {
            defer { isLoading = false; work = nil }
            do {
                _ = try await finish()
                try Task.checkCancellation()
                owner.authenticationChanged(for: source.id)
                dismiss()
            } catch is CancellationError { return }
            catch { self.error = message(error) }
        }
    }
    private func message(_ error: Error) -> String {
        if case ScraperError.interactionRequired = error { return localized("來源需要互動登入") }
        return (error as? RSSWebFailure)?.localizedDescription ?? localized("來源配置腳本錯誤")
    }
}

#Preview("RSS login form") {
    var source = RSSSource(name: "Preview", url: "https://example.invalid")
    source.loginUi = "[{\"name\":\"User\",\"type\":\"text\"},{\"name\":\"Password\",\"type\":\"password\"}]"
    return NavigationStack { RSSSourceLoginView(source: source, owner: .shared) }
}
