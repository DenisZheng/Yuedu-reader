import SwiftUI
import WebKit

/// 已解析的入口目标。保留请求method/body/headers和HTML，不再交给只接受裸URL的SafariView。
/// 页面资源、RSS动作桥和媒体合同继续在S6接入；这里不向网页暴露源脚本的java对象。
struct RSSSourcePageSheet: View {
    let source: RSSSource
    let target: RSSOpenTarget
    var owner: RSSStore? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var error: String?
    @State private var loading = true

    var body: some View {
        NavigationStack {
            RSSSourcePageWebView(source: source, target: target, error: $error, loading: $loading, owner: owner)
                .overlay(alignment: .top) {
                    if loading { ProgressView().padding(DSSpacing.md) }
                    if let error {
                        Text(error).font(DSFont.footnote).padding(DSSpacing.md)
                            .background(DSColor.surface)
                    }
                }
                .navigationTitle(source.name)
                .toolbarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button { dismiss() } label: { Image(systemName: "xmark") }
                            .accessibilityLabel(localized("關閉"))
                    }
                }
        }
    }
}

struct RSSSourcePageWebView: UIViewRepresentable {
    let source: RSSSource
    let target: RSSOpenTarget
    @Binding var error: String?
    @Binding var loading: Bool
    var owner: RSSStore? = nil
    var findRequestID: Binding<UUID?> = .constant(nil)

    func makeCoordinator() -> Coordinator { Coordinator(error: $error, loading: $loading) }
    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = source.enableJs
        if case .html = target, source.enableJs, let script = source.startJs, !script.isEmpty {
            configuration.userContentController.addUserScript(WKUserScript(source: script, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        }
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.isFindInteractionEnabled = true
        return view
    }
    func updateUIView(_ view: WKWebView, context: Context) {
        if let id = findRequestID.wrappedValue, id != context.coordinator.handledFindID {
            context.coordinator.handledFindID = id
            view.findInteraction?.presentFindNavigator(showingReplace: false)
        }
        guard context.coordinator.loaded != target || context.coordinator.loadedSource != source else { return }
        context.coordinator.load(target, source: source, owner: owner, into: view)
    }
    static func dismantleUIView(_ view: WKWebView, coordinator: Coordinator) {
        coordinator.cancel()
        view.stopLoading()
        view.navigationDelegate = nil
        view.configuration.userContentController.removeAllUserScripts()
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var loaded: RSSOpenTarget?
        var loadedSource: RSSSource?
        private var task: Task<Void, Never>?
        private var generation = 0
        var handledFindID: UUID?
        private var error: Binding<String?>
        private var loading: Binding<Bool>
        init(error: Binding<String?>, loading: Binding<Bool>) { self.error = error; self.loading = loading }
        func cancel() {
            generation &+= 1
            task?.cancel()
            task = nil
        }
        func load(_ target: RSSOpenTarget, source: RSSSource, owner: RSSStore?, into view: WKWebView) {
            cancel()
            loaded = target
            loadedSource = source
            let id = generation
            let ticket = owner?.requestTicket(for: source.id)
            task = Task { [weak view] in
                loading.wrappedValue = true
                error.wrappedValue = nil
                defer { if id == generation { task = nil } }
                do {
                    switch target {
                    case .request(let request):
                        let document = try await RSSOpenTarget.loadDocument(request, source: source, owner: owner)
                        try Task.checkCancellation()
                        guard id == generation else { return }
                        if let owner { guard let ticket, owner.accepts(ticket) else { throw CancellationError() } }
                        view?.load(document.data, mimeType: document.mimeType, characterEncodingName: document.encoding, baseURL: document.url)
                    case .html(let html, let base):
                        let style = source.startStyle.map { "<style>\($0)</style>" } ?? ""
                        view?.loadHTMLString(style + html, baseURL: source.loadWithBaseUrl ? URL(string: base) : nil)
                    case .external: loading.wrappedValue = false
                    }
                } catch is CancellationError { return }
                catch { if id == generation { fail(error) } }
            }
        }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { loading.wrappedValue = false }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError failure: Error) { fail(failure) }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError failure: Error) { fail(failure) }
        private func fail(_ failure: Error) {
            guard (failure as NSError).code != NSURLErrorCancelled else { return }
            loading.wrappedValue = false
            error.wrappedValue = localized("HTTP 請求失敗")
        }
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            let scheme = navigationAction.request.url?.scheme?.lowercased()
            decisionHandler(["http", "https", "about"].contains(scheme ?? "") ? .allow : .cancel)
        }
    }
}

#Preview("RSS startup HTML") {
    RSSSourcePageSheet(source: RSSSource(name: "Preview", url: "https://example.invalid/"),
                       target: .html("<h1>RSS</h1><p>Preview</p>", baseURL: "https://example.invalid/"))
}
