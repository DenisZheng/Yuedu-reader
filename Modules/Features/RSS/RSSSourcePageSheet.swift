import SwiftUI
import WebKit

/// 已解析的入口目标。保留请求method/body/headers和HTML，不再交给只接受裸URL的SafariView。
/// 规则HTML和首文档共用WebKit生命周期；不向页面暴露源脚本的java对象。
struct RSSSourcePageSheet: View {
    let source: RSSSource
    let target: RSSOpenTarget
    var owner: RSSStore? = nil
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            RSSSourcePageScreen(source: source, target: target, owner: owner)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button { dismiss() } label: { Image(systemName: "xmark") }
                            .accessibilityLabel(localized("關閉"))
                    }
                }
        }
    }
}

/// 推入与模态共用同一个页面，不在动作目的页再套一层NavigationStack。
struct RSSSourcePageScreen: View {
    let source: RSSSource
    let target: RSSOpenTarget
    var owner: RSSStore?
    var title: String? = nil
    @State private var error: String?
    @State private var loading = true
    @State private var reloadID = UUID()
    @State private var router = RSSWebActionRouter()
    @State private var isVisible = false
    var body: some View {
        RSSSourcePageWebView(source: source, target: target, error: $error, loading: $loading, owner: owner,
            onAction: { request in
                guard let owner else { throw RSSWebFailure.actionUnavailable }
                try router.receive(request, source: source, owner: owner)
            }, isActive: isVisible)
            .id(reloadID)
            .overlay(alignment: .top) {
                if loading { ProgressView().padding(DSSpacing.md) }
                if let error {
                    VStack(spacing: DSSpacing.sm) {
                        Text(error).font(DSFont.footnote)
                        Button { reloadID = UUID() } label: {
                            Text(localized("重試")).frame(minWidth: DSLayout.minimumTapTarget, minHeight: DSLayout.minimumTapTarget)
                        }
                        .accessibilityIdentifier("rss.web.retry")
                    }
                    .padding(DSSpacing.md).background(DSColor.surface)
                }
            }
            .navigationTitle(title ?? source.name)
            .toolbarTitleDisplayMode(.inline)
            .modifier(RSSWebActionPresentation(router: router, owner: owner))
            .onAppear { isVisible = true }
            .onDisappear { isVisible = false; router.cancelPending() }
    }
}

@MainActor @Observable final class RSSWebAuthenticationBridge {
    var finish: (() async throws -> String)?
}

struct RSSSourcePageWebView: UIViewRepresentable {
    let source: RSSSource
    let target: RSSOpenTarget
    @Binding var error: String?
    @Binding var loading: Bool
    var owner: RSSStore? = nil
    var findRequestID: Binding<UUID?> = .constant(nil)
    var restoreScrollY: Double = 0
    var onScrollYChange: ((Double) -> Void)?
    var article: RSSArticleRecord? = nil
    var onAction: ((RSSWebActionRequest) throws -> Void)? = nil
    var isActive = true
    var authentication = false
    var authenticationBridge: RSSWebAuthenticationBridge? = nil
    var initialRequestContext: RSSOpenTarget.RequestContext? = nil

    func makeCoordinator() -> Coordinator { Coordinator(error: $error, loading: $loading) }
    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = authentication || source.enableJs
        configuration.websiteDataStore = .nonPersistent()
        configuration.setURLSchemeHandler(context.coordinator.images, forURLScheme: RSSWebImages.scheme)
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.uiDelegate = context.coordinator
        view.isFindInteractionEnabled = true
        view.scrollView.delegate = context.coordinator
        context.coordinator.attachCookies(configuration.websiteDataStore.httpCookieStore)
        context.coordinator.observeScrollSize(view.scrollView)
        return view
    }
    func updateUIView(_ view: WKWebView, context: Context) {
        context.coordinator.onScrollYChange = onScrollYChange
        context.coordinator.onAction = onAction
        context.coordinator.isPageActive = isActive
        context.coordinator.authentication = authentication
        context.coordinator.authenticationBridge = authenticationBridge
        authenticationBridge?.finish = { [weak view, weak coordinator = context.coordinator] in
            guard let view, let coordinator, !coordinator.isRevoked, coordinator.accessState?.isCurrent == true else { throw CancellationError() }
            try await coordinator.webCookies?.flush()
            // 导航切换期间documentElement可能为空；明确报“未就绪”，不把页面异常当成结果。
            guard let html = try await view.evaluateJavaScript("document.documentElement ? document.documentElement.outerHTML : null") as? String else { throw RSSWebFailure.resourceUnavailable }
            return html
        }
        if let id = findRequestID.wrappedValue, id != context.coordinator.handledFindID {
            context.coordinator.handledFindID = id
            view.findInteraction?.presentFindNavigator(showingReplace: false)
        }
        guard context.coordinator.loaded != target || context.coordinator.loadedSource != source
                || context.coordinator.loadedOwnerID != owner?.runtimeIdentity || context.coordinator.loadedArticleID != article?.id else { return }
        context.coordinator.load(target, source: source, owner: owner, restoreScrollY: restoreScrollY, into: view,
                                 article: article, initialContext: initialRequestContext)
    }
    static func dismantleUIView(_ view: WKWebView, coordinator: Coordinator) {
        coordinator.commitScroll(view.scrollView)
        coordinator.cancel()
        coordinator.stopObservingScrollSize()
        coordinator.resetCookies()
        coordinator.authenticationBridge?.finish = nil
        view.scrollView.delegate = nil
        view.stopLoading()
        view.navigationDelegate = nil
        view.uiDelegate = nil
        view.configuration.userContentController.removeAllUserScripts()
        view.configuration.userContentController.removeScriptMessageHandler(forName: RSSWebConsoleLog.name)
        view.configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        // WebView尚被系统/测试持有时，stopLoading本身不会销毁已完成的JS/iframe文档。
        view.loadHTMLString("", baseURL: nil)
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, UIScrollViewDelegate {
        var loaded: RSSOpenTarget?
        var loadedSource: RSSSource?
        var loadedOwnerID: String?
        var loadedArticleID: String?
        var onAction: ((RSSWebActionRequest) throws -> Void)?
        let images = RSSWebImages()
        let webLog = RSSWebConsoleLog()
        var isPageActive = true
        var authentication = false
        weak var authenticationBridge: RSSWebAuthenticationBridge?
        private let dialogs = SourceWebUIDelegate()
        private weak var loadedOwner: RSSStore?
        private var pageArticle: RSSArticleRecord?
        private var requestContext: RSSOpenTarget.RequestContext?
        private var pageURL: URL?
        private var expectedNativeURL: URL?
        private var runtimeForPage: RSSRuntime?
        private var sourceScriptsAllowed = true
        fileprivate var webCookies: RSSWebCookies?
        private weak var currentView: WKWebView?
        private var bridgePrompt: String?
        private var bridgeTask: Task<Void, Never>?
        private var navigationTask: Task<Void, Never>?
        private var task: Task<Void, Never>?
        private var injectionTask: Task<Void, Never>?
        private var generation = 0
        // 页面权限覆盖其全部原生导航；不能与每次导航的完成/注入generation混用。
        private var accessGeneration = 0
        private var navigation: WKNavigation?
        private var pendingRestore: Double?
        private var sizeObservation: NSKeyValueObservation?
        private var documentIsReady = false
        fileprivate var accessState: RSSRuntimeState?
        private var accessToken: UUID?
        private var loginObserver: NSObjectProtocol?
        fileprivate var isRevoked = false
        var onScrollYChange: ((Double) -> Void)?
        var handledFindID: UUID?
        private var error: Binding<String?>
        private var loading: Binding<Bool>
        init(error: Binding<String?>, loading: Binding<Bool>) { self.error = error; self.loading = loading }
        func attachCookies(_ cookieStore: WKHTTPCookieStore) {
            let adapter = RSSWebCookies(cookieStore)
            adapter.onFailure = { [weak self] failure in self?.fail(failure) }
            webCookies = adapter
            images.onFailure = { [weak self] failure in self?.fail(failure) }
            images.onCookiesChanged = { [weak self] in try await self?.webCookies?.synchronizeFromNative() }
        }
        func resetCookies() {
            guard let webCookies else { return }
            webCookies.reset()
            self.webCookies = nil
        }
        private func cookieHeader(_ context: RSSOpenTarget.RequestContext?, for url: URL) -> String? {
            guard let context, context.requestURL.flatMap(SourceRequestHeaderScope.origin) == SourceRequestHeaderScope.origin(url) else { return nil }
            return context.headers.first { $0.key.lowercased() == "cookie" }?.value
        }
        func cancel() {
            generation &+= 1
            accessGeneration &+= 1
            if let accessToken { accessState?.removeCancellation(accessToken) }
            accessToken = nil
            accessState = nil
            if let loginObserver { NotificationCenter.default.removeObserver(loginObserver) }
            loginObserver = nil
            navigationTask?.cancel()
            navigationTask = nil
            expectedNativeURL = nil
            bridgePrompt = nil
            bridgeTask?.cancel()
            bridgeTask = nil
            runtimeForPage = nil
            task?.cancel()
            task = nil
            injectionTask?.cancel()
            injectionTask = nil
            navigation = nil
            documentIsReady = false
            images.reset()
        }
        func load(_ target: RSSOpenTarget, source: RSSSource, owner: RSSStore?, restoreScrollY: Double, into view: WKWebView,
                  article: RSSArticleRecord? = nil, followingNavigation: Bool = false,
                  initialContext: RSSOpenTarget.RequestContext? = nil) {
            cancel()
            if !followingNavigation {
                loaded = target
                loadedArticleID = article?.id
                pageArticle = article
                requestContext = initialContext
                sourceScriptsAllowed = !authentication
            }
            loadedSource = source
            currentView = view
            loadedOwner = owner
            loadedOwnerID = owner?.runtimeIdentity
            isRevoked = false
            pendingRestore = restoreScrollY.isFinite ? max(0, restoreScrollY) : 0
            view.stopLoading()
            let controller = view.configuration.userContentController
            controller.removeAllUserScripts()
            view.configuration.defaultWebpagePreferences.allowsContentJavaScript = authentication || source.enableJs
            let id = generation
            let accessID = accessGeneration
            let ticket = owner?.requestTicket(for: source.id)
            task = Task { [weak view] in
                loading.wrappedValue = true
                error.wrappedValue = nil
                defer { if id == generation { task = nil } }
                do {
                    // 复用Store登记的共享运行时撤销，不靠View订阅全库或轮询票据。
                    let runtime = try await RSSRuntime.make(source: source, owner: owner)
                    try Task.checkCancellation()
                    guard id == generation, let view else { return }
                    accessState = runtime.state
                    runtimeForPage = runtime
                    accessToken = runtime.state.addCancellation { [weak self, weak view] in
                        Task { @MainActor [weak self, weak view] in
                            guard let self, let view, accessID == self.accessGeneration else { return }
                            self.revoke(view)
                        }
                    }
                    let authenticationKey = RSSRuntime.authenticationKey(for: source)
                    loginObserver = NotificationCenter.default.addObserver(forName: .bookSourceLoginInfoDidChange, object: nil, queue: nil) { [weak self, weak view] note in
                        guard note.userInfo?["sourceURL"] as? String == authenticationKey else { return }
                        Task { @MainActor [weak self, weak view] in
                            guard let self, let view, accessID == self.accessGeneration,
                                  self.accessState?.isCurrent == false else { return }
                            self.revoke(view)
                        }
                    }
                    guard runtime.state.isCurrent else { throw CancellationError() }
                    switch target {
                    case .request(let request, let context):
                        let document = try await authentication
                            ? RSSOpenTarget.loadAuthenticationDocument(request, context: context, source: source, owner: owner)
                            : RSSOpenTarget.loadDocument(request, context: context, source: source, owner: owner)
                        try Task.checkCancellation()
                        guard id == generation else { return }
                        if let owner { guard let ticket, owner.accepts(ticket) else { throw CancellationError() } }
                        requestContext = document.context
                        runtimeForPage = runtime
                        pageURL = document.url
                        try await webCookies?.bind(runtime: runtime, url: document.url, explicit: cookieHeader(document.context, for: document.url))
                        try Task.checkCancellation()
                        guard id == generation else { return }
                        sourceScriptsAllowed = sourceScriptsAllowed && request.url.flatMap(SourceRequestHeaderScope.origin) == SourceRequestHeaderScope.origin(document.url)
                        try await images.bind(source: source, context: requestContext, base: document.url, runtime: runtime, in: view, authentication: authentication)
                        let bytes = document.mimeType.lowercased().contains("html")
                            ? Data(try await images.rewrite(String(decoding: document.data, as: UTF8.self)).utf8) : document.data
                        try await installSourceScripts(source, in: view)
                        try Task.checkCancellation()
                        guard id == generation else { return }
                        expectedNativeURL = document.url
                        navigation = view.load(bytes, mimeType: document.mimeType, characterEncodingName: document.encoding, baseURL: document.url)
                    case .html(let html, let base), .articleHTML(let html, let base):
                        let isStartup: Bool
                        if case .html = target { isStartup = true } else { isStartup = false }
                        let document = await SourceScriptThread.run {
                            RSSRuleWebDocument(content: html, base: base, source: source, isStartup: isStartup)
                        }
                        try Task.checkCancellation()
                        guard id == generation else { return }
                        if let owner { guard let ticket, owner.accepts(ticket) else { throw CancellationError() } }
                        if let baseURL = document.baseURL, SourceRequestHeaderScope.origin(baseURL) != nil {
                            if requestContext == nil {
                                let info = pageArticle.map { RSSOpenTarget.RequestContext.Article(title: $0.title, link: $0.link, category: $0.categoryName ?? "", id: $0.id) }
                                let prepared = SourcePreparedWebRequest(request: URLRequest(url: baseURL), responseOptions: .init(), variables: pageArticle?.variables ?? [:])
                                let seeded = try await RSSOpenTarget.navigation(prepared.request, source: source,
                                    context: .init(prepared, runtime: runtime, article: info), owner: owner)
                                if case .request(_, let context) = seeded { requestContext = context }
                            }
                            try await webCookies?.bind(runtime: runtime, url: baseURL, explicit: cookieHeader(requestContext, for: baseURL))
                        } else { requestContext = nil }
                        try Task.checkCancellation()
                        guard id == generation else { return }
                        pageURL = document.baseURL
                        try await images.bind(source: source, context: requestContext, base: document.baseURL, runtime: runtime, in: view, authentication: authentication)
                        let html = try await images.rewrite(document.html)
                        try await installSourceScripts(source, in: view)
                        try Task.checkCancellation()
                        guard id == generation else { return }
                        expectedNativeURL = document.baseURL ?? URL(string: "about:blank")
                        navigation = view.loadHTMLString(html, baseURL: document.baseURL)
                    case .external: loading.wrappedValue = false
                    }
                } catch is CancellationError {
                    if id == generation, !Task.isCancelled, let view { revoke(view) }
                }
                catch { if id == generation { fail(error) } }
            }
        }
        private func installSourceScripts(_ source: RSSSource, in view: WKWebView) async throws {
            let controller = view.configuration.userContentController
            controller.removeAllUserScripts()
            controller.removeScriptMessageHandler(forName: RSSWebConsoleLog.name)
            if source.showWebLog == true, source.enableJs, !authentication {
                webLog.reset(sourceName: source.name)
                controller.add(webLog, name: RSSWebConsoleLog.name)
                controller.addUserScript(WKUserScript(source: RSSWebConsoleLog.script, injectionTime: .atDocumentStart, forMainFrameOnly: false))
            }
            bridgePrompt = nil
            view.customUserAgent = requestContext?.headers.first { $0.key.lowercased() == "user-agent" }?.value
            let preload = sourceScriptsAllowed ? source.preloadJs ?? "" : ""
            guard source.enableJs, !preload.isEmpty || images.needsPipeline else { return }
            let name = "__readerRSS_" + UUID().uuidString
            if images.needsPipeline {
                controller.addUserScript(WKUserScript(source: RSSWebImages.bootstrap(prompt: name), injectionTime: .atDocumentStart, forMainFrameOnly: true))
            }
            if !preload.isEmpty {
                let script = await RSSWebPageBridge.bootstrap(prompt: name, preload: preload)
                try Task.checkCancellation()
                guard accessState?.isCurrent == true else { throw CancellationError() }
                controller.addUserScript(WKUserScript(source: script, injectionTime: .atDocumentStart, forMainFrameOnly: true))
            }
            bridgePrompt = name
        }
        private func acceptsBridge(_ frame: WKFrameInfo, in view: WKWebView) -> Bool {
            guard isPageActive, UIApplication.shared.applicationState == .active, currentView === view, frame.isMainFrame, !isRevoked,
                  (authentication || loadedSource?.enableJs == true), accessState?.isCurrent == true else { return false }
            guard let expected = pageURL.flatMap(SourceRequestHeaderScope.origin) else {
                return frame.securityOrigin.host.isEmpty && (frame.request.url?.scheme == "about" || frame.request.url == nil)
            }
            let origin = frame.securityOrigin
            let port = origin.port == 0 ? (origin.protocol.lowercased() == "https" ? 443 : 80) : origin.port
            return "\(origin.protocol.lowercased())://\(origin.host.lowercased()):\(port)" == expected
                && frame.request.url.flatMap(SourceRequestHeaderScope.origin) == expected
        }
        func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?,
                     initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor (String?) -> Void) {
            if !prompt.hasPrefix("__readerRSS_") {
                dialogs.webView(webView, runJavaScriptTextInputPanelWithPrompt: prompt, defaultText: defaultText,
                                initiatedByFrame: frame, completionHandler: completionHandler)
                return
            }
            guard prompt == bridgePrompt, acceptsBridge(frame, in: webView), let runtime = runtimeForPage,
                  let payload = defaultText, payload.utf8.count <= 65_536 else { completionHandler(nil); return }
            let id = generation
            bridgeTask?.cancel()
            bridgeTask = Task { [weak webView] in
                var response: String?
                defer { completionHandler(response) }
                do {
                    let command = try await RSSWebPageBridge.decode(payload)
                    try Task.checkCancellation()
                    guard id == generation, bridgePrompt == prompt, let webView, acceptsBridge(frame, in: webView) else { return }
                    switch command {
                    case .image(let raw): response = try images.register(raw)
                    case .srcset(let raw): response = try images.registerSrcset(raw)
                    case .originalImage(let raw): response = images.original(raw)
                    case .action(let action):
                        guard sourceScriptsAllowed else { throw RSSWebFailure.actionUnavailable }
                        try deliver(action, authority: .page)
                        response = ""
                    default:
                        guard sourceScriptsAllowed else { throw RSSWebFailure.actionUnavailable }
                        let value = try await RSSWebPageBridge.execute(command, runtime: runtime)
                        try Task.checkCancellation()
                        guard id == generation, bridgePrompt == prompt, acceptsBridge(frame, in: webView) else { return }
                        response = value
                    }
                } catch is CancellationError { }
                catch { if id == generation { fail(error) } }
            }
        }
        private func deliver(_ action: RSSWebAction, authority: RSSWebActionRequest.Authority) throws {
            guard isPageActive, UIApplication.shared.applicationState == .active, accessState?.isCurrent == true,
                  let runtime = runtimeForPage, let onAction else { throw RSSWebFailure.actionUnavailable }
            try onAction(.init(action: action, authority: authority, sourceID: runtime.source.id,
                               ownerID: runtime.owner?.runtimeIdentity, ticket: runtime.ticket, baseURL: pageURL, context: requestContext,
                               credentialRevision: LoginManager.shared.loginInfoRevision(sourceUrl: RSSRuntime.authenticationKey(for: runtime.source))))
        }
        func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                     initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor () -> Void) {
            dialogs.webView(webView, runJavaScriptAlertPanelWithMessage: message, initiatedByFrame: frame, completionHandler: completionHandler)
        }
        func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                     initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor (Bool) -> Void) {
            dialogs.webView(webView, runJavaScriptConfirmPanelWithMessage: message, initiatedByFrame: frame, completionHandler: completionHandler)
        }
        private func revoke(_ view: WKWebView) {
            cancel()
            isRevoked = true
            webCookies?.reset()
            pendingRestore = nil
            view.stopLoading()
            view.configuration.userContentController.removeAllUserScripts()
            view.configuration.defaultWebpagePreferences.allowsContentJavaScript = false
            // 替换旧JS realm，终止计时器/iframe/媒体，而不只是停止仍在加载的主请求。
            navigation = view.loadHTMLString("", baseURL: nil)
            loading.wrappedValue = false
            error.wrappedValue = localized("訂閱來源或登入狀態已變更，請重新開啟")
        }
        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            if self.navigation !== navigation {
                generation &+= 1
                injectionTask?.cancel()
                self.navigation = navigation
            }
            documentIsReady = false
        }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard !isRevoked, self.navigation === navigation else { return }
            guard accessState?.isCurrent == true else { revoke(webView); return }
            let id = generation
            injectionTask?.cancel()
            injectionTask = Task { [weak webView] in
                defer { if id == generation { injectionTask = nil } }
                do {
                    guard id == generation, accessState?.isCurrent == true else {
                        if id == generation, let webView { revoke(webView) }
                        return
                    }
                    try await webCookies?.flush()
                    if sourceScriptsAllowed, loadedSource?.enableJs == true, let script = loadedSource?.injectJs, !script.isEmpty, let webView {
                        _ = try await webView.evaluateJavaScript(script)
                    }
                    try await webCookies?.flush()
                    try Task.checkCancellation()
                    guard id == generation, let webView else { return }
                    guard accessState?.isCurrent == true else { revoke(webView); return }
                    webView.layoutIfNeeded()
                    documentIsReady = true
                    restoreScrollIfReady(webView.scrollView)
                    loading.wrappedValue = false
                } catch is CancellationError { return }
                catch { if id == generation { fail(error, script: true) } }
            }
        }
        func observeScrollSize(_ view: UIScrollView) {
            sizeObservation = view.observe(\.contentSize, options: [.new]) { [weak self] view, _ in
                Task { @MainActor [weak self, weak view] in
                    guard let self, let view else { return }
                    self.restoreScrollIfReady(view)
                }
            }
        }
        func stopObservingScrollSize() { sizeObservation?.invalidate(); sizeObservation = nil }
        private func restoreScrollIfReady(_ view: UIScrollView) {
            guard !isRevoked, accessState?.isCurrent == true, documentIsReady, let offset = pendingRestore,
                  view.contentSize.height > view.bounds.height || offset == 0 else { return }
            pendingRestore = nil
            let maxY = max(0, view.contentSize.height - view.bounds.height)
            view.setContentOffset(CGPoint(x: 0, y: min(offset, maxY)), animated: false)
        }
        func scrollViewWillBeginDragging(_ scrollView: UIScrollView) { pendingRestore = nil }

        // 滚动中不发布到Store；手势结束/离开时提交，页面禁用JS也不会丢进度。
        func commitScroll(_ scrollView: UIScrollView) {
            guard !isRevoked, accessState?.isCurrent == true, documentIsReady, pendingRestore == nil else { return }
            onScrollYChange?(max(0, scrollView.contentOffset.y))
        }
        func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
            if !decelerate { commitScroll(scrollView) }
        }
        func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) { commitScroll(scrollView) }
        func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) { commitScroll(scrollView) }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError failure: Error) {
            if self.navigation === navigation { fail(failure) }
        }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError failure: Error) {
            if self.navigation === navigation { fail(failure) }
        }
        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            if !isRevoked { fail(WKError(.webContentProcessTerminated)) }
        }
        private func fail(_ failure: Error, script: Bool = false) {
            guard (failure as NSError).code != NSURLErrorCancelled else { return }
            loading.wrappedValue = false
            error.wrappedValue = script ? localized("來源網頁腳本執行失敗") : (failure as? RSSWebFailure)?.errorDescription ?? localized("載入失敗")
        }
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
            guard let url = navigationAction.request.url else { decisionHandler(.cancel); return }
            let scheme = url.scheme?.lowercased() ?? ""
            if !isRevoked, let accessState, !accessState.isCurrent {
                revoke(webView); decisionHandler(.cancel); return
            }
            if isRevoked {
                decisionHandler(url.absoluteString == "about:blank" ? .allow : .cancel); return
            }
            if let expectedNativeURL, url == expectedNativeURL, navigationAction.targetFrame?.isMainFrame != false {
                self.expectedNativeURL = nil
                decisionHandler(.allow); return
            }
            if navigationAction.targetFrame?.isMainFrame == false {
                decisionHandler(["http", "https", "about"].contains(scheme) ? .allow : .cancel); return
            }
            guard navigationAction.sourceFrame.isMainFrame, let source = loadedSource else {
                decisionHandler(.cancel); return
            }
            if authentication, ["http", "https"].contains(scheme) {
                // 登录网站的真实表单body由WebKit拥有，不经过无法取得body的原生重送路径。
                // 后续原生网页导航不继承初始私有头，也不保留源/图片桥进入另一个站点。
                webView.configuration.userContentController.removeAllUserScripts()
                bridgePrompt = nil; images.reset()
                decisionHandler(.allow)
                return
            }
            let request = navigationAction.request
            let context = requestContext
            let owner = loadedOwner
            let id = generation
            let mayRunSource = sourceScriptsAllowed
            let currentURL = pageURL
            navigationTask?.cancel()
            navigationTask = Task { [weak webView] in
                var replied = false
                defer { if !replied { decisionHandler(.cancel) } }
                do {
                    try await webCookies?.flush()
                    let result = mayRunSource ? try await RSSWebNavigation.intercept(url, source: source, context: context, owner: owner)
                        : .init(intercepted: false, actions: [])
                    try Task.checkCancellation()
                    guard id == generation, !isRevoked, accessState?.isCurrent == true, let webView else { return }
                    if !result.actions.isEmpty {
                        for action in result.actions { try deliver(action, authority: .sourceRule) }
                    }
                    if result.intercepted { return }
                    if ["http", "https"].contains(scheme), SourceRequestHeaderScope.origin(url) == currentURL.flatMap(SourceRequestHeaderScope.origin) {
                        var old = currentURL.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }
                        var next = URLComponents(url: url, resolvingAgainstBaseURL: false)
                        old?.fragment = nil; next?.fragment = nil
                        if url.fragment != nil, old?.url == next?.url {
                            replied = true; decisionHandler(.allow); return
                        }
                        let target = try await RSSOpenTarget.navigation(request, source: source, context: context, owner: owner)
                        try Task.checkCancellation()
                        guard id == generation, accessState?.isCurrent == true else { return }
                        replied = true; decisionHandler(.cancel)
                        load(target, source: source, owner: owner, restoreScrollY: 0, into: webView, followingNavigation: true)
                    } else if let destination = RSSLinkRoute.route(url).url {
                        try deliver(.external(destination), authority: .page)
                    } else { throw RSSWebFailure.navigationBlocked }
                } catch is CancellationError { }
                catch { if id == generation { fail(error) } }
            }
        }
    }
}

#Preview("RSS interactive article") {
    var source = RSSSource(name: "Preview", url: "https://example.invalid/")
    source.ruleArticles = "class.item"
    return RSSSourcePageSheet(source: source, target: .articleHTML(
        "<button onclick=\"this.textContent='Done'\">Preview</button>", baseURL: source.url))
}

#Preview("RSS startup HTML") {
    RSSSourcePageSheet(source: RSSSource(name: "Preview", url: "https://example.invalid/"),
                       target: .html("<h1>RSS</h1><p>Preview</p>", baseURL: "https://example.invalid/"))
}
