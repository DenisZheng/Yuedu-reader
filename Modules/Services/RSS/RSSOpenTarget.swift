import Foundation

/// 展示目标保留原始HTML/请求；不在入口阶段去脚本、改URL或提前抓列表。
enum RSSOpenTarget: Equatable, Sendable {
    case request(URLRequest)
    case html(String, baseURL: String)
    case external(URL)

    var webURL: InAppWebURL? {
        guard case .request(let request) = self, let url = request.url else { return nil }
        return InAppWebURL(url)
    }

    struct Document: Sendable {
        let data: Data
        let mimeType: String
        let encoding: String
        let url: URL
    }

    /// WebKit原生重定向会重发自定义头；首文档先走共享网络边界，再把响应交给WebKit。
    /// 不重发POST、不把私有头写入页面，也不接管http(s)子资源scheme。
    static func loadDocument(_ request: URLRequest, source: RSSSource, owner: RSSStore? = nil,
                             session: URLSession = LegadoJSBridge.requestSession) async throws -> Document {
        let runtime = try await RSSRuntime.make(source: source, owner: owner, requestSession: session)
        return try await runtime.run { _ in
            let executor = SourceRequestExecutor(session: session, rate: source.concurrentRate ?? "",
                rateKey: RSSRuntime.authenticationKey(for: source), cookieJarEnabled: source.enabledCookieJar, runtimeState: runtime.state)
            let (data, response) = try await executor.data(for: request)
            try Task.checkCancellation()
            guard let http = response as? HTTPURLResponse, let url = http.url else { throw ScraperError.httpError }
            guard (200..<300).contains(http.statusCode) else { throw ScraperError.httpStatus(http.statusCode) }
            return Document(data: data, mimeType: http.mimeType ?? "text/html", encoding: http.textEncodingName ?? "utf-8", url: url)
        }
    }

    static func originalArticle(_ article: RSSArticleRecord, source: RSSSource, owner: RSSStore? = nil,
                                session: URLSession = LegadoJSBridge.requestSession) async throws -> Self {
        if case .system(let url) = RSSLinkRoute.route(article.link, relativeTo: source.articleLinkBaseURL) {
            return .external(url)
        }
        let runtime = try await RSSRuntime.make(source: source, owner: owner, requestSession: session)
        return try await runtime.run { host in
            try await host.run { bridge in
                let data = RuleData()
                data.variableMap = article.variables ?? [:]
                let object = RSSArticleScriptObject(source: source, sortName: article.categoryName ?? "", data: data)
                object.link = article.link
                object.title = article.title
                return try bridge.withRuleContext(content: "", baseURL: source.sourceKey, scope: data,
                                                   bindings: ["rssArticle": object], stage: "rss.content") { _ in
                    .request(try bridge.prepareRuleWebRequest(LegadoRSSScraper.normalizedRequestURL(article.link)))
                }
            }
        }
    }

    static func resolve(source: RSSSource, owner: RSSStore? = nil,
                        session: URLSession = LegadoJSBridge.requestSession) async throws -> Self? {
        guard source.opensAsWebPage || source.startHtml?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else { return nil }
        let runtime = try await RSSRuntime.make(source: source, owner: owner, requestSession: session)
        return try await runtime.run { host in
            try await host.run { bridge in
                func evaluate(_ raw: String) throws -> String {
                    guard LegadoSortURLParser.needsJSEvaluation(raw) else { return raw }
                    return try bridge.withRuleContext(content: "", baseURL: source.sourceKey, scope: nil) {
                        $0.getString(ruleStr: "@js:" + (LegadoSortURLParser.jsBody(raw) ?? ""))
                    }
                }
                if source.opensAsWebPage {
                    let sort = source.sortUrl?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    let value = try evaluate(sort.isEmpty ? source.sourceKey : sort)
                    let parts = value.components(separatedBy: "::")
                    let raw = parts.count > 1 ? parts[1] : value
                    if case .system(let url) = RSSLinkRoute.route(raw, relativeTo: nil) { return .external(url) }
                    let request = try bridge.prepareRuleWebRequest(LegadoRSSScraper.normalizedRequestURL(raw))
                    return .request(request)
                }
                let html = try evaluate(source.startHtml ?? "")
                return html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : .html(html, baseURL: source.sourceKey)
            }
        }
    }
}
