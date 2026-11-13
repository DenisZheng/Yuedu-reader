import Foundation

/// 仅无需原生响应处理的独立网页直接导航；有规则/私有头的请求仍使用共享执行器。
/// 不识别站点、验证码或HTTP状态，也不在失败后切换请求栈。
enum RSSNativeBrowserPolicy {
    static func allows(_ request: URLRequest, source: RSSSource, context: RSSOpenTarget.RequestContext?) -> Bool {
        guard source.opensAsWebPage, source.enabledCookieJar, source.cacheFirst != true,
              context?.article == nil, (request.httpMethod ?? "GET").uppercased() == "GET",
              request.httpBody == nil, request.httpBodyStream == nil,
              let url = request.url, SourceRequestHeaderScope.origin(url) != nil,
              url.user == nil, url.password == nil else { return false }
        let requiresNativeProcessing = [
            context?.responseOptions.charset, context?.responseOptions.bodyJs,
            source.loginUrl, source.loginUi, source.loginCheckJs, source.jsLib,
            source.preloadJs, source.injectJs, source.startJs, source.coverDecodeJs,
            source.shouldOverrideUrlLoading, source.contentWhitelist, source.contentBlacklist,
            source.concurrentRate
        ].contains { $0?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false }
        guard !requiresNativeProcessing, source.preload != true, source.showWebLog != true else { return false }
        // 显式Cookie、Authorization和自定义头不可由WebKit重定向隐式继承；不靠事后拦截阻止泄漏。
        let publicHeaders: Set<String> = ["user-agent", "accept", "accept-language", "accept-encoding", "cache-control", "pragma"]
        return (request.allHTTPHeaderFields ?? [:]).keys.allSatisfy { publicHeaders.contains($0.lowercased()) }
    }
}
