import Foundation

/// 展示目标保留原始HTML/请求；不在入口阶段去脚本、改URL或提前抓列表。
enum RSSOpenTarget: Equatable, Sendable {
    case request(URLRequest, context: RequestContext? = nil)
    case html(String, baseURL: String)
    case articleHTML(String, baseURL: String)
    case external(URL)

    var webURL: InAppWebURL? {
        guard case .request(let request, _) = self, let url = request.url else { return nil }
        return InAppWebURL(url)
    }

    struct RequestContext: Equatable, Sendable {
        struct Article: Equatable, Sendable {
            var title: String
            var link: String
            var category: String
            var id: String? = nil
        }
        var responseOptions: SourceResponseOptions
        var variables: [String: String]
        var article: Article?
        var ticket: RSSRequestTicket?
        var ownerID: String?
        var credentialRevision: UInt64
        var requestURL: URL?
        var headers: [String: String]
        init(_ prepared: SourcePreparedWebRequest, runtime: RSSRuntime, article: Article? = nil) {
            responseOptions = prepared.responseOptions
            variables = prepared.variables
            self.article = article
            requestURL = prepared.request.url
            headers = prepared.request.allHTTPHeaderFields ?? [:]
            ticket = runtime.ticket
            ownerID = runtime.owner?.runtimeIdentity
            credentialRevision = LoginManager.shared.loginInfoRevision(sourceUrl: RSSRuntime.authenticationKey(for: runtime.source))
        }
        func bindings(source: RSSSource, data: RuleData) -> [String: Any] {
            guard let article else { return [:] }
            let value = RSSArticleScriptObject(source: source, sortName: article.category, data: data)
            value.title = article.title; value.link = article.link
            return ["rssArticle": value]
        }
        func validate(source: RSSSource, owner: RSSStore?) async throws {
            if let ticket {
                guard let owner, await owner.runtimeIdentity == ownerID,
                      ticket.sourceID == source.id, await owner.accepts(ticket) else { throw CancellationError() }
            }
            guard credentialRevision == LoginManager.shared.loginInfoRevision(sourceUrl: RSSRuntime.authenticationKey(for: source))
            else { throw CancellationError() }
        }
    }

    struct Document: Sendable {
        let data: Data
        let mimeType: String
        let encoding: String
        let url: URL
        var context: RequestContext? = nil
        /// 只供原生边界的状态诊断，不传给网页或改变响应处理。
        var statusCode: Int? = nil
    }

    /// 带私有头或响应规则的首文档先走共享网络边界，防止WebKit重定向继承私有头。
    /// 不重发POST、不把私有头写入页面，也不接管http(s)子资源scheme。
    static func loadDocument(_ request: URLRequest, context: RequestContext? = nil, source: RSSSource, owner: RSSStore? = nil,
                             session: URLSession = LegadoJSBridge.requestSession) async throws -> Document {
        try await context?.validate(source: source, owner: owner)
        let runtime = try await RSSRuntime.make(source: source, owner: owner, requestSession: session)
        return try await runtime.run { host in
            // 同源turn排队期间可能由其他流程刷新凭据；取得turn后才是发送边界。
            try await context?.validate(source: source, owner: owner)
            let executor = SourceRequestExecutor(session: session, rate: source.concurrentRate ?? "",
                rateKey: RSSRuntime.authenticationKey(for: source), cookieJarEnabled: source.enabledCookieJar, runtimeState: runtime.state)
            let cacheKey = RSSWebDocumentCache.key(request, source: source)
            let cached = cacheKey.flatMap(RSSWebDocumentCache.lookup)
            let data: Data, response: URLResponse
            if let cached { (data, response) = (cached.0, cached.1) }
            else { (data, response) = try await executor.data(for: request) }
            try Task.checkCancellation()
            guard runtime.state.isCurrent, let http = response as? HTTPURLResponse else { throw ScraperError.httpError }
            let result = try await host.run { bridge in
                let scope = RuleData()
                scope.variableMap = context?.variables ?? [:]
                let bindings = context?.bindings(source: source, data: scope) ?? [:]
                return try bridge.withRuleContext(content: "", baseURL: request.url?.absoluteString ?? source.sourceKey,
                                                   scope: scope, bindings: bindings, stage: "rss.web") { _ in
                    let value = try bridge.finishRuleWebRequest(data: data, response: response, request: request,
                                                                options: context?.responseOptions ?? .init())
                    let prepared = SourcePreparedWebRequest(request: request, responseOptions: context?.responseOptions ?? .init(), variables: scope.variableMap)
                    return (value.body, value.url, value.status, RequestContext(prepared, runtime: runtime, article: context?.article))
                }
            }
            guard (200..<300).contains(result.2) else { throw ScraperError.httpStatus(result.2) }
            guard let url = URL(string: result.1) else { throw ScraperError.invalidURL }
            // 登录检查通过后才写；未命中才写，避免读缓存时刷新其LRU之外的内容。
            if cached == nil, result.2 == 200, let cacheKey { RSSWebDocumentCache.store(data, response: http, key: cacheKey) }
            let mime = http.mimeType ?? "text/html"
            let transformed = context?.responseOptions.bodyJs?.isEmpty == false
            let textual = mime.hasPrefix("text/") || mime.contains("json") || mime.contains("xml") || transformed
            return Document(data: textual ? Data(result.0.utf8) : data, mimeType: transformed ? "text/html" : mime,
                            encoding: textual ? "utf-8" : http.textEncodingName ?? "utf-8", url: url, context: result.3, statusCode: result.2)
        }
    }

    /// 登录网页不运行正文loginCheck/bodyJs，也不等待正在startBrowserAwait的同源JS turn。
    /// 仍复用请求、Cookie域策略、限流和源撤销；正文解码使用原共享解码器。
    static func loadAuthenticationDocument(_ raw: URLRequest, context: RequestContext?, source: RSSSource, owner: RSSStore?,
                                            session: URLSession = LegadoJSBridge.requestSession) async throws -> Document {
        try await context?.validate(source: source, owner: owner)
        let runtime = try await RSSRuntime.make(source: source, owner: owner, requestSession: session)
        var request = raw
        if let context, context.requestURL.flatMap(SourceRequestHeaderScope.origin) == raw.url.flatMap(SourceRequestHeaderScope.origin) {
            for (name, value) in context.headers where request.value(forHTTPHeaderField: name) == nil { request.setValue(value, forHTTPHeaderField: name) }
        }
        let executor = SourceRequestExecutor(session: session, rate: source.concurrentRate ?? "",
            rateKey: RSSRuntime.authenticationKey(for: source), cookieJarEnabled: true, runtimeState: runtime.state,
            cookieScope: SourceRequestHeaderScope(urls: [request.url].compactMap { $0 }), maximumBytes: 8 * 1_024 * 1_024)
        let (data, response) = try await executor.data(for: request)
        try Task.checkCancellation()
        guard runtime.state.isCurrent, let http = response as? HTTPURLResponse, let url = http.url,
              (200..<600).contains(http.statusCode) else { throw RSSWebFailure.resourceUnavailable }
        let mime = http.mimeType ?? "text/html"
        let bytes: Data
        if mime.hasPrefix("text/") || mime.contains("html") || mime.contains("xml") {
            guard let body = HTMLResponseDecoder.decode(data: data, response: response, declaredCharset: context?.responseOptions.charset) else { throw RSSWebFailure.resourceUnavailable }
            bytes = Data(body.utf8)
        } else { bytes = data }
        let prepared = SourcePreparedWebRequest(request: request, responseOptions: .init(), variables: [:])
        return Document(data: bytes, mimeType: mime, encoding: "utf-8", url: url, context: .init(prepared, runtime: runtime, article: nil), statusCode: http.statusCode)
    }

    static func rulePage(_ raw: String, source: RSSSource, owner: RSSStore?, context: RequestContext? = nil) async throws -> Self {
        let runtime = try await RSSRuntime.make(source: source, owner: owner)
        return try await runtime.run { host in
            try await host.run { bridge in
                let scope = RuleData(); scope.variableMap = context?.variables ?? [:]
                return try bridge.withRuleContext(content: "", baseURL: source.sourceKey, scope: scope,
                                                  bindings: context?.bindings(source: source, data: scope) ?? [:], stage: "rss.navigation") { _ in
                    let value = try bridge.prepareRuleWebRequest(LegadoRSSScraper.normalizedRequestURL(raw), scope: scope)
                    return .request(value.request, context: .init(value, runtime: runtime, article: context?.article))
                }
            }
        }
    }

    static func navigation(_ request: URLRequest, source: RSSSource, context: RequestContext?, owner: RSSStore?) async throws -> Self {
        let method = (request.httpMethod ?? "GET").uppercased()
        guard ["GET", "HEAD"].contains(method) || request.httpBody != nil else { throw RSSWebFailure.formBodyUnavailable }
        try await context?.validate(source: source, owner: owner)
        let runtime = try await RSSRuntime.make(source: source, owner: owner)
        return try await runtime.run { host in
            try await host.run { bridge in
                let scope = RuleData(); scope.variableMap = context?.variables ?? [:]
                return try bridge.withRuleContext(content: "", baseURL: request.url?.absoluteString ?? "", scope: scope,
                                                  bindings: context?.bindings(source: source, data: scope) ?? [:], stage: "rss.navigation") { _ in
                    var value = try bridge.prepareNativeWebRequest(request, scope: scope)
                    if let context, let old = context.requestURL, let target = request.url,
                       SourceRequestHeaderScope.origin(old) == SourceRequestHeaderScope.origin(target) {
                        for (key, header) in context.headers where value.request.value(forHTTPHeaderField: key) == nil
                            && !["content-length", "content-type", "host", "origin", "referer"].contains(key.lowercased()) {
                            value.request.setValue(header, forHTTPHeaderField: key)
                        }
                    }
                    return .request(value.request, context: .init(value, runtime: runtime, article: context?.article))
                }
            }
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
                    let request = try bridge.prepareRuleWebRequest(LegadoRSSScraper.normalizedRequestURL(article.link), scope: data)
                    return .request(request.request, context: .init(request, runtime: runtime, article: .init(title: article.title, link: article.link,
                                                                                         category: article.categoryName ?? "", id: article.id)))
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
                    return .request(request.request, context: .init(request, runtime: runtime))
                }
                let html = try evaluate(source.startHtml ?? "")
                return html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : .html(html, baseURL: source.sourceKey)
            }
        }
    }
}
