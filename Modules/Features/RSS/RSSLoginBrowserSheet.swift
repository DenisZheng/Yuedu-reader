import SwiftUI

/// Foreground-only source verification. Login website scripts run, but never receive the RSS source API.
@MainActor struct RSSLoginBrowserSheet: View {
    let source: RSSSource
    let owner: RSSStore
    let page: RSSLoginInteractionState.Browser
    let state: RSSLoginInteractionState
    @Environment(\.dismiss) private var dismiss
    @State private var bridge = RSSWebAuthenticationBridge()
    @State private var error: String?
    @State private var loading = true
    @State private var isFinishing = false

    var body: some View {
        NavigationStack {
            RSSSourcePageWebView(source: source, target: page.target, error: $error, loading: $loading,
                owner: owner, authentication: true, authenticationBridge: bridge, initialRequestContext: page.context)
                .navigationTitle(page.title.isEmpty ? source.name : page.title)
                .toolbarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button { state.finish(nil); dismiss() } label: { Image(systemName: "xmark") }
                            .accessibilityLabel(localized("取消"))
                            .disabled(isFinishing)
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button { finish() } label: { Image(systemName: "checkmark") }
                            .accessibilityLabel(localized("完成"))
                            .disabled(isFinishing || loading || page.awaitsResult && bridge.finish == nil)
                    }
                }
        }
        .interactiveDismissDisabled(isFinishing)
        .onDisappear { if page.awaitsResult, state.browser?.id == page.id { state.finish(nil) } }
    }
    private func finish() {
        guard !isFinishing else { return }
        isFinishing = true
        if !page.awaitsResult { state.finish(nil); dismiss(); return }
        Task {
            do {
                guard let callback = bridge.finish else { throw RSSWebFailure.resourceUnavailable }
                let html = try await callback()
                guard !Task.isCancelled, let ticket = page.context?.ticket, owner.accepts(ticket) else { throw CancellationError() }
                state.finish(html); dismiss()
            } catch is CancellationError { state.finish(nil); dismiss() }
            catch { self.error = RSSWebFailure.resourceUnavailable.localizedDescription; isFinishing = false }
        }
    }
}

#Preview("RSS browser login") {
    let owner = RSSStore.shared
    let source = RSSSource(name: "Preview", url: "https://example.invalid/")
    let state = RSSLoginInteractionState()
    let target = RSSOpenTarget.articleHTML("<p>Login preview</p>", baseURL: source.url)
    return RSSLoginBrowserSheet(source: source, owner: owner,
        page: .init(target: target, title: "Preview", awaitsResult: false, context: nil), state: state)
}
