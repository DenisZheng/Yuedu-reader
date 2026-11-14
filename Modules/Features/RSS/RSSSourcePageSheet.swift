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
                        Button { dismiss() } label: {
                            Image(systemName: "xmark")
                                .frame(minWidth: DSLayout.minimumTapTarget, minHeight: DSLayout.minimumTapTarget)
                        }
                        .accessibilityLabel(localized("關閉"))
                        .accessibilityIdentifier("rss.web.close")
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
    @State private var displayScalePercent = 100
    @State private var webNavigation = RSSWebNavigationState()
    var body: some View {
        RSSSourcePageWebView(source: source, target: target, error: $error, loading: $loading, owner: owner,
            webNavigation: webNavigation,
            onAction: { request in
                guard let owner else { throw RSSWebFailure.actionUnavailable }
                try router.receive(request, source: source, owner: owner)
            }, isActive: isVisible, displayScalePercent: displayScalePercent)
            .id(reloadID)
            .overlay(alignment: .top) {
                if loading { ProgressView().padding(DSSpacing.md) }
                if let error {
                    VStack(spacing: DSSpacing.sm) {
                        Text(error).font(DSFont.footnote)
                        Button {
                            webNavigation.reset()
                            reloadID = UUID()
                        } label: {
                            Text(localized("重試")).frame(minWidth: DSLayout.minimumTapTarget, minHeight: DSLayout.minimumTapTarget)
                        }
                        .accessibilityIdentifier("rss.web.retry")
                    }
                    .padding(DSSpacing.md).background(DSColor.surface)
                }
            }
            .navigationTitle(title ?? source.name)
            .toolbarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    if webNavigation.canGoBack {
                        Button { webNavigation.goBack() } label: {
                            Image(systemName: "arrow.backward")
                                .frame(minWidth: DSLayout.minimumTapTarget, minHeight: DSLayout.minimumTapTarget)
                        }
                        .accessibilityLabel(localized("網頁返回"))
                        .accessibilityIdentifier("rss.web.back")
                    }
                    Menu {
                        Picker(localized("網頁縮放"), selection: $displayScalePercent) {
                            ForEach(RSSWebViewport.percentages, id: \.self) { percent in
                                Text(RSSWebViewport.label(percent)).tag(percent)
                            }
                        }
                    } label: {
                        Label(localized("網頁縮放"), systemImage: "plus.magnifyingglass")
                            .labelStyle(.iconOnly)
                            .frame(minWidth: DSLayout.minimumTapTarget, minHeight: DSLayout.minimumTapTarget)
                    }
                    .accessibilityLabel(String(format: localized("網頁縮放：%@"), RSSWebViewport.label(displayScalePercent)))
                    .accessibilityIdentifier("rss.web.scale")
                }
            }
            .modifier(RSSWebActionPresentation(router: router, owner: owner))
            .onAppear { isVisible = true }
            .onDisappear { isVisible = false; router.cancelPending() }
    }
}

@MainActor @Observable final class RSSWebNavigationState {
    private(set) var canGoBack = false
    @ObservationIgnored fileprivate weak var coordinator: RSSSourcePageWebView.Coordinator?

    func goBack() {
        guard canGoBack else { return }
        coordinator?.goBack()
    }

    fileprivate func update(canGoBack value: Bool) {
        guard canGoBack != value else { return }
        canGoBack = value
    }

    fileprivate func reset() { update(canGoBack: false) }
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
    var webNavigation: RSSWebNavigationState? = nil
    var findRequestID: Binding<UUID?> = .constant(nil)
    var restoreScrollY: Double = 0
    var onScrollYChange: ((Double) -> Void)?
    var article: RSSArticleRecord? = nil
    var onAction: ((RSSWebActionRequest) throws -> Void)? = nil
    var isActive = true
    var authentication = false
    var authenticationBridge: RSSWebAuthenticationBridge? = nil
    var initialRequestContext: RSSOpenTarget.RequestContext? = nil
    /// 仅独立网页提供主动显示缩放；文章/登录默认不参与。
    var displayScalePercent: Int? = nil

    func makeCoordinator() -> Coordinator { Coordinator(error: $error, loading: $loading) }
    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = authentication || source.enableJs
        configuration.websiteDataStore = .nonPersistent()
        configuration.ignoresViewportScaleLimits = displayScalePercent != nil && !authentication
        configuration.setURLSchemeHandler(context.coordinator.images, forURLScheme: RSSWebImages.scheme)
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.uiDelegate = context.coordinator
        view.isFindInteractionEnabled = true
        view.scrollView.delegate = context.coordinator
        context.coordinator.attachCookies(configuration.websiteDataStore.httpCookieStore)
        context.coordinator.observeScrollSize(view.scrollView)
        context.coordinator.observeHistory(view)
        return view
    }
    func updateUIView(_ view: WKWebView, context: Context) {
        context.coordinator.onScrollYChange = onScrollYChange
        context.coordinator.attachNavigationState(webNavigation, to: view)
        context.coordinator.onAction = onAction
        context.coordinator.isPageActive = isActive
        context.coordinator.authentication = authentication
        context.coordinator.updateDisplayScale(authentication ? nil : displayScalePercent, in: view)
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
        coordinator.stopObservingHistory()
        coordinator.detachNavigationState()
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
        private var displayTask: Task<Void, Never>?
        private var displayRevision: UInt64 = 0
        private var requestedPercent: Int?
        private var pendingPercent: Int?
        private var appliedPercent: Int?
        private var generation = 0
        // 页面权限覆盖其全部原生导航；不能与每次导航的完成/注入generation混用。
        private var accessGeneration = 0
        private var navigation: WKNavigation?
        private var pendingRestore: Double?
        private var sizeObservation: NSKeyValueObservation?
        private var historyObservation: NSKeyValueObservation?
        private var urlObservation: NSKeyValueObservation?
        private weak var webNavigationState: RSSWebNavigationState?
        private struct HistoryEntry {
            var target: RSSOpenTarget
            var context: RSSOpenTarget.RequestContext?
            var sourceScriptsAllowed: Bool
            var scrollY: Double = 0
        }
        // 仅记录共享执行器的导航目标；返回仍走原来的加载管线，不另存HTML响应缓存。
        private var pageHistory: [HistoryEntry] = []
        private var pageHistoryIndex = -1
        private var pendingHistoryTarget: RSSOpenTarget?
        private var pendingHistoryIndex: Int?
        private var documentHistoryRoot: WKBackForwardListItem?
        private var containerPreviousItems: [WKBackForwardListItem] = []
        private var documentPreviousItems: [WKBackForwardListItem] = []
        private var documentIsReady = false
        private var diagnosticAttempt: RSSWebLoadDiagnostics.Attempt?
        private var diagnosticFailureRecorded = false
        private var nativeBrowser = false
        private var nativeHTTPStatus: Int?
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
            adapter.onFailure = { [weak self] failure in self?.fail(failure, phase: .cookies) }
            webCookies = adapter
            images.onFailure = { [weak self] failure in self?.fail(failure, phase: .resources) }
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
        private func cancelDisplayScale() {
            displayRevision &+= 1
            displayTask?.cancel()
            displayTask = nil
            pendingPercent = nil
            appliedPercent = nil
        }
        func updateDisplayScale(_ percent: Int?, in view: WKWebView) {
            requestedPercent = percent
            guard documentIsReady, !isRevoked, !authentication, accessState?.isCurrent == true,
                  let percent, percent != appliedPercent, percent != pendingPercent else { return }
            cancelDisplayScale()
            pendingPercent = percent
            let revision = displayRevision
            let id = generation
            displayTask = Task { [weak self, weak view] in
                guard let self else { return }
                defer {
                    if revision == displayRevision { pendingPercent = nil; displayTask = nil }
                }
                do {
                    try Task.checkCancellation()
                    guard id == generation, let view, accessState?.isCurrent == true else { return }
                    let applied = try await RSSWebViewport.apply(percent, revision: revision, in: view)
                    try Task.checkCancellation()
                    guard id == generation, revision == displayRevision, accessState?.isCurrent == true, applied else { return }
                    appliedPercent = percent
                    if error.wrappedValue == RSSWebFailure.viewportUnavailable.errorDescription { error.wrappedValue = nil }
                } catch is CancellationError { return }
                catch {
                    guard id == generation, revision == displayRevision else { return }
                    fail(RSSWebFailure.viewportUnavailable)
                }
            }
        }
        func cancel() {
            diagnosticAttempt = nil
            nativeBrowser = false
            nativeHTTPStatus = nil
            cancelDisplayScale()
            generation &+= 1
            accessGeneration &+= 1
            if let accessToken { accessState?.removeCancellation(accessToken) }
            accessToken = nil
            accessState = nil
            if webNavigationState?.coordinator === self { webNavigationState?.reset() }
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
                  initialContext: RSSOpenTarget.RequestContext? = nil, historyIndex: Int? = nil) {
            if documentIsReady, pageHistory.indices.contains(pageHistoryIndex) {
                pageHistory[pageHistoryIndex].scrollY = max(0, view.scrollView.contentOffset.y)
            }
            cancel()
            diagnosticAttempt = RSSWebLoadDiagnostics.Attempt(source: source)
            diagnosticFailureRecorded = false
            RSSWebLoadDiagnostics.record(diagnosticAttempt, .started, phase: .runtime)
            documentHistoryRoot = nil
            pendingHistoryTarget = webNavigationState == nil ? nil : target
            pendingHistoryIndex = historyIndex
            if let historyIndex, pageHistory.indices.contains(historyIndex) {
                requestContext = pageHistory[historyIndex].context
                sourceScriptsAllowed = pageHistory[historyIndex].sourceScriptsAllowed
            }
            if !followingNavigation {
                pageHistory.removeAll()
                pageHistoryIndex = -1
                containerPreviousItems.removeAll()
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
                var diagnosticPhase = RSSWebLoadDiagnostics.Phase.runtime
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
                        diagnosticPhase = .document
                        if !authentication, RSSNativeBrowserPolicy.allows(request, source: source, context: context) {
                            try await context?.validate(source: source, owner: owner)
                            guard let url = request.url else { throw ScraperError.invalidURL }
                            requestContext = context
                            pageURL = url
                            diagnosticPhase = .cookies
                            try await webCookies?.bind(runtime: runtime, url: url, explicit: nil)
                            try Task.checkCancellation()
                            guard id == generation, runtime.state.isCurrent else { throw CancellationError() }
                            try await context?.validate(source: source, owner: owner)
                            // 第一请求及后续表单留在同一WebKit会话；Cookie只通过域约束的cookieStore播种。
                            nativeBrowser = true
                            sourceScriptsAllowed = false
                            view.customUserAgent = request.value(forHTTPHeaderField: "User-Agent")
                            var browserRequest = request
                            browserRequest.setValue(nil, forHTTPHeaderField: "User-Agent")
                            browserRequest.cachePolicy = .reloadIgnoringLocalCacheData
                            expectedNativeURL = url
                            diagnosticPhase = .browser
                            navigation = view.load(browserRequest)
                            RSSWebLoadDiagnostics.record(diagnosticAttempt, .submitted, phase: .browser)
                            return
                        }
                        let document = try await authentication
                            ? RSSOpenTarget.loadAuthenticationDocument(request, context: context, source: source, owner: owner)
                            : RSSOpenTarget.loadDocument(request, context: context, source: source, owner: owner)
                        try Task.checkCancellation()
                        guard id == generation else { return }
                        if let owner { guard let ticket, owner.accepts(ticket) else { throw CancellationError() } }
                        requestContext = document.context
                        runtimeForPage = runtime
                        pageURL = document.url
                        RSSWebLoadDiagnostics.record(diagnosticAttempt, .received, phase: .document,
                                                    statusCode: document.statusCode, bytes: document.data.count)
                        diagnosticPhase = .cookies
                        try await webCookies?.bind(runtime: runtime, url: document.url, explicit: cookieHeader(document.context, for: document.url))
                        try Task.checkCancellation()
                        guard id == generation else { return }
                        sourceScriptsAllowed = sourceScriptsAllowed && request.url.flatMap(SourceRequestHeaderScope.origin) == SourceRequestHeaderScope.origin(document.url)
                        diagnosticPhase = .resources
                        try await images.bind(source: source, context: requestContext, base: document.url, runtime: runtime, in: view, authentication: authentication)
                        let bytes = document.mimeType.lowercased().contains("html")
                            ? Data(try await images.rewrite(String(decoding: document.data, as: UTF8.self)).utf8) : document.data
                        diagnosticPhase = .scripts
                        try await installSourceScripts(source, in: view)
                        try Task.checkCancellation()
                        guard id == generation else { return }
                        diagnosticPhase = .webkit
                        expectedNativeURL = document.url
                        if webNavigationState != nil {
                            // loadData的文档不进入历史；已取得的内容用公开API建立可返回的WebKit历史项。
                            let response = URLResponse(url: document.url, mimeType: document.mimeType, expectedContentLength: bytes.count, textEncodingName: document.encoding)
                            navigation = view.loadSimulatedRequest(URLRequest(url: document.url), response: response, responseData: bytes)
                        } else {
                            navigation = view.load(bytes, mimeType: document.mimeType, characterEncodingName: document.encoding, baseURL: document.url)
                        }
                        RSSWebLoadDiagnostics.record(diagnosticAttempt, .submitted, phase: diagnosticPhase)
                    case .html(let html, let base), .articleHTML(let html, let base):
                        let isStartup: Bool
                        if case .html = target { isStartup = true } else { isStartup = false }
                        diagnosticPhase = .html
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
                            diagnosticPhase = .cookies
                            try await webCookies?.bind(runtime: runtime, url: baseURL, explicit: cookieHeader(requestContext, for: baseURL))
                        } else { requestContext = nil }
                        try Task.checkCancellation()
                        guard id == generation else { return }
                        pageURL = document.baseURL
                        diagnosticPhase = .resources
                        try await images.bind(source: source, context: requestContext, base: document.baseURL, runtime: runtime, in: view, authentication: authentication)
                        let html = try await images.rewrite(document.html)
                        diagnosticPhase = .scripts
                        try await installSourceScripts(source, in: view)
                        try Task.checkCancellation()
                        guard id == generation else { return }
                        diagnosticPhase = .webkit
                        expectedNativeURL = document.baseURL ?? URL(string: "about:blank")
                        if webNavigationState != nil, let url = expectedNativeURL {
                            navigation = view.loadSimulatedRequest(URLRequest(url: url), responseHTML: html)
                        } else {
                            navigation = view.loadHTMLString(html, baseURL: document.baseURL)
                        }
                        RSSWebLoadDiagnostics.record(diagnosticAttempt, .submitted, phase: diagnosticPhase)
                    case .external: loading.wrappedValue = false
                    }
                } catch is CancellationError {
                    if id == generation, !Task.isCancelled, let view { revoke(view) }
                }
                catch { if id == generation { fail(error, phase: diagnosticPhase) } }
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
            publishHistoryState(webView)
            if self.navigation !== navigation {
                generation &+= 1
                injectionTask?.cancel()
                self.navigation = navigation
                if nativeBrowser, let source = loadedSource {
                    diagnosticAttempt = RSSWebLoadDiagnostics.Attempt(source: source)
                    diagnosticFailureRecorded = false
                    RSSWebLoadDiagnostics.record(diagnosticAttempt, .started, phase: .browser)
                }
            }
            if nativeBrowser {
                nativeHTTPStatus = nil
                loading.wrappedValue = true
                error.wrappedValue = nil
            }
            cancelDisplayScale()
            documentIsReady = false
        }
        func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                     decisionHandler: @escaping @MainActor (WKNavigationResponsePolicy) -> Void) {
            guard nativeBrowser, navigationResponse.isForMainFrame else { decisionHandler(.allow); return }
            guard !isRevoked, accessState?.isCurrent == true,
                  let http = navigationResponse.response as? HTTPURLResponse, let url = http.url,
                  SourceRequestHeaderScope.origin(url) == pageURL.flatMap(SourceRequestHeaderScope.origin),
                  navigationResponse.canShowMIMEType else {
                decisionHandler(.cancel)
                fail(RSSWebFailure.navigationBlocked, phase: .browser)
                return
            }
            nativeHTTPStatus = http.statusCode
            pageURL = url
            RSSWebLoadDiagnostics.record(diagnosticAttempt, .received, phase: .browser, statusCode: http.statusCode)
            if (400..<600).contains(http.statusCode) {
                error.wrappedValue = String(format: localized("RSS 請求失敗：HTTP %d"), http.statusCode)
            }
            decisionHandler(.allow)
        }
        func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
            guard webNavigationState != nil, !isRevoked, accessState?.isCurrent == true, self.navigation === navigation else { return }
            pageURL = webView.url
            if let target = pendingHistoryTarget {
                if let index = pendingHistoryIndex {
                    pageHistoryIndex = index
                } else {
                    pageHistory.removeSubrange((pageHistoryIndex + 1)..<pageHistory.count)
                    pageHistory.append(HistoryEntry(target: target, context: requestContext, sourceScriptsAllowed: sourceScriptsAllowed))
                    // 有限的页面导航元数据，不让长期网页浏览保留无界请求上下文。
                    if pageHistory.count > 100 { pageHistory.removeFirst() }
                    pageHistoryIndex = pageHistory.count - 1
                }
                pendingHistoryTarget = nil
                pendingHistoryIndex = nil
                documentHistoryRoot = webView.backForwardList.currentItem
                documentPreviousItems = webView.backForwardList.backList
                if pageHistoryIndex == 0 { containerPreviousItems = documentPreviousItems }
            }
            publishHistoryState(webView)
        }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard !isRevoked, self.navigation === navigation else { return }
            guard accessState?.isCurrent == true else { revoke(webView); return }
            let id = generation
            injectionTask?.cancel()
            injectionTask = Task { [weak webView] in
                var diagnosticPhase = RSSWebLoadDiagnostics.Phase.cookies
                defer { if id == generation { injectionTask = nil } }
                do {
                    guard id == generation, accessState?.isCurrent == true else {
                        if id == generation, let webView { revoke(webView) }
                        return
                    }
                    diagnosticPhase = .cookies
                    try await webCookies?.flush()
                    diagnosticPhase = .scripts
                    if sourceScriptsAllowed, loadedSource?.enableJs == true, let script = loadedSource?.injectJs, !script.isEmpty, let webView {
                        _ = try await webView.evaluateJavaScript(script)
                    }
                    diagnosticPhase = .cookies
                    try await webCookies?.flush()
                    try Task.checkCancellation()
                    guard id == generation, let webView else { return }
                    guard accessState?.isCurrent == true else { revoke(webView); return }
                    webView.layoutIfNeeded()
                    documentIsReady = true
                    updateDisplayScale(requestedPercent, in: webView)
                    restoreScrollIfReady(webView.scrollView)
                    loading.wrappedValue = false
                    diagnosticPhase = .webkit
                    publishHistoryState(webView)
                    RSSWebLoadDiagnostics.record(diagnosticAttempt, .finished, phase: nativeBrowser ? .browser : diagnosticPhase,
                                                statusCode: nativeBrowser ? nativeHTTPStatus : nil)
                } catch is CancellationError { return }
                catch { if id == generation { fail(error, script: true, phase: diagnosticPhase) } }
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
        func observeHistory(_ view: WKWebView) {
            historyObservation = view.observe(\.canGoBack, options: [.initial, .new]) { [weak self, weak view] _, _ in
                Task { @MainActor [weak self, weak view] in
                    guard let self, let view else { return }
                    self.publishHistoryState(view)
                }
            }
            urlObservation = view.observe(\.url, options: [.new]) { [weak self, weak view] _, _ in
                Task { @MainActor [weak self, weak view] in
                    guard let self, let view else { return }
                    self.publishHistoryState(view)
                }
            }
        }
        func stopObservingHistory() {
            historyObservation?.invalidate(); historyObservation = nil
            urlObservation?.invalidate(); urlObservation = nil
        }
        func attachNavigationState(_ state: RSSWebNavigationState?, to view: WKWebView) {
            if webNavigationState !== state {
                if webNavigationState?.coordinator === self {
                    webNavigationState?.coordinator = nil
                    webNavigationState?.reset()
                }
                webNavigationState = state
                state?.coordinator = self
            }
            publishHistoryState(view)
        }
        func detachNavigationState() {
            if webNavigationState?.coordinator === self {
                webNavigationState?.coordinator = nil
                webNavigationState?.reset()
            }
            webNavigationState = nil
        }
        private func hasHistory(excluding boundary: [WKBackForwardListItem], in view: WKWebView) -> Bool {
            guard view.canGoBack, let previous = view.backForwardList.backItem else { return false }
            return !boundary.contains { $0 === previous }
        }
        private func hasHistoryWithinDocument(_ view: WKWebView) -> Bool {
            documentHistoryRoot != nil && hasHistory(excluding: documentPreviousItems, in: view)
        }
        private func publishHistoryState(_ view: WKWebView) {
            guard webNavigationState?.coordinator === self else { return }
            let hasPrevious = pageHistoryIndex >= 0 && (nativeBrowser ? hasHistory(excluding: containerPreviousItems, in: view)
                : pageHistoryIndex > 0 || hasHistoryWithinDocument(view))
            webNavigationState?.update(canGoBack: hasPrevious && !isRevoked && accessState?.isCurrent == true)
        }
        fileprivate func goBack() {
            guard let view = currentView else { return }
            goBack(in: view)
        }
        private func goBack(in view: WKWebView) {
            guard !isRevoked, accessState?.isCurrent == true else { publishHistoryState(view); return }
            navigationTask?.cancel()
            navigationTask = nil
            if nativeBrowser || hasHistoryWithinDocument(view) {
                guard nativeBrowser ? hasHistory(excluding: containerPreviousItems, in: view) : view.canGoBack
                else { publishHistoryState(view); return }
                view.goBack()
            } else if pageHistoryIndex > 0, let source = loadedSource {
                let index = pageHistoryIndex - 1
                let entry = pageHistory[index]
                if case .request(let request, _) = entry.target,
                   !["GET", "HEAD"].contains((request.httpMethod ?? "GET").uppercased()) {
                    fail(RSSWebFailure.formBodyUnavailable, phase: .navigation)
                    return
                }
                // 带响应规则/私有头的整页返回必须重走共享执行器，重绑该页脚本与图片上下文。
                load(entry.target, source: source, owner: loadedOwner, restoreScrollY: entry.scrollY, into: view,
                     article: pageArticle, followingNavigation: true, historyIndex: index)
            }
        }
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
            if self.navigation === navigation { fail(failure, phase: .navigation) }
            publishHistoryState(webView)
        }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError failure: Error) {
            if self.navigation === navigation { fail(failure, phase: .provisional) }
            publishHistoryState(webView)
        }
        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            if !isRevoked { fail(WKError(.webContentProcessTerminated), phase: .webProcess) }
        }
        private func fail(_ failure: Error, script: Bool = false, phase: RSSWebLoadDiagnostics.Phase = .webkit) {
            guard (failure as NSError).code != NSURLErrorCancelled else { return }
            if !diagnosticFailureRecorded {
                RSSWebLoadDiagnostics.record(diagnosticAttempt, .failed, phase: phase, failure: failure)
                diagnosticFailureRecorded = true
            }
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
            let currentDocumentURL = webView.url
            let reloadedHistoryIndex = webNavigationState != nil && navigationAction.navigationType == .reload && pageHistoryIndex >= 0
                ? pageHistoryIndex : nil
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
                    // 同文档返回（含去掉hash及about:blank）只遍历历史，不重发整个页面。
                    var previous = currentDocumentURL.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }
                    var next = URLComponents(url: url, resolvingAgainstBaseURL: false)
                    let fragmentNavigation = previous?.fragment != nil || next?.fragment != nil
                    previous?.fragment = nil; next?.fragment = nil
                    if let previousURL = previous?.url, previousURL == next?.url,
                       fragmentNavigation || (navigationAction.navigationType == .backForward && hasHistoryWithinDocument(webView)),
                       (["http", "https"].contains(scheme) && SourceRequestHeaderScope.origin(url) == currentURL.flatMap(SourceRequestHeaderScope.origin))
                            || previousURL.absoluteString == "about:blank" {
                        try await requestContext?.validate(source: source, owner: owner)
                        guard id == generation, accessState?.isCurrent == true, !Task.isCancelled else { return }
                        replied = true; decisionHandler(.allow); return
                    }
                    if nativeBrowser, ["http", "https"].contains(scheme), url.user == nil, url.password == nil,
                       SourceRequestHeaderScope.origin(url) == currentURL.flatMap(SourceRequestHeaderScope.origin) {
                        try await requestContext?.validate(source: source, owner: owner)
                        guard id == generation, accessState?.isCurrent == true, !Task.isCancelled else { return }
                        // 原始表单body、Referer、Cookie及浏览器状态由WebKit拥有；不取消后再复制成URLSession请求。
                        replied = true; decisionHandler(.allow); return
                    }
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
                        let scrollY = reloadedHistoryIndex.map { pageHistory[$0].scrollY } ?? 0
                        load(target, source: source, owner: owner, restoreScrollY: scrollY, into: webView,
                             followingNavigation: true, historyIndex: reloadedHistoryIndex)
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
