import Foundation

/// RSS音视频复用共享AnalyzeUrl与SourceRequestExecutor；AVPlayer只访问当前会话的有界资源端点，不持有源凭据。
enum RSSMediaRequestService {
    struct Prepared: Sendable {
        var request: URLRequest
        var context: RSSOpenTarget.RequestContext
        var runtime: RSSRuntime
    }
    nonisolated static func prepare(_ raw: String, source: RSSSource, base: URL?, context: RSSOpenTarget.RequestContext?,
                                    owner: RSSStore?, trustedRuleURL: Bool,
                                    article: RSSOpenTarget.RequestContext.Article? = nil) async throws -> Prepared {
        try await context?.validate(source: source, owner: owner)
        let runtime = try await RSSRuntime.make(source: source, owner: owner)
        return try await runtime.run { host in
            try await host.run { bridge in
                let scope = RuleData(); scope.variableMap = context?.variables ?? [:]
                let boundArticle = context?.article ?? article
                var requestContext = context?.bindings(source: source, data: scope) ?? [:]
                if requestContext.isEmpty, let boundArticle {
                    let object = RSSArticleScriptObject(source: source, sortName: boundArticle.category, data: scope)
                    object.title = boundArticle.title; object.link = boundArticle.link
                    requestContext["rssArticle"] = object
                }
                return try bridge.withRuleContext(content: "", baseURL: base?.absoluteString ?? source.sourceKey,
                    scope: scope, bindings: requestContext, stage: "rss.media.prepare") { _ in
                    let prepared: SourcePreparedWebRequest
                    if trustedRuleURL { prepared = try bridge.prepareRuleWebRequest(LegadoRSSScraper.normalizedRequestURL(raw), scope: scope) }
                    else {
                        let url = try RSSWebActionRouter.pageURL(raw, base: base)
                        var value = try bridge.prepareNativeWebRequest(URLRequest(url: url), scope: scope)
                        if SourceRequestHeaderScope.origin(url) == (context?.requestURL ?? base).flatMap(SourceRequestHeaderScope.origin) {
                            for (name, header) in context?.headers ?? [:] where value.request.value(forHTTPHeaderField: name) == nil {
                                value.request.setValue(header, forHTTPHeaderField: name)
                            }
                        }
                        prepared = value
                    }
                    guard let url = prepared.request.url, SourceRequestHeaderScope.origin(url) != nil else { throw RSSWebFailure.navigationBlocked }
                    let link = RSSOpenTarget.RequestContext(prepared, runtime: runtime, article: boundArticle)
                    return Prepared(request: prepared.request, context: link, runtime: runtime)
                }
            }
        }
    }
    nonisolated static func stream(_ prepared: Prepared) async throws -> (VideoStream, RSSMediaResourceSession) {
        guard prepared.runtime.state.isCurrent, let url = prepared.request.url,
              SourceRequestHeaderScope.origin(url) != nil, url.user == nil, url.password == nil,
              (prepared.request.httpMethod ?? "GET").uppercased() == "GET", prepared.request.httpBody == nil else {
            throw RSSWebFailure.resourceUnavailable
        }
        let resources = try RSSMediaResourceSession(prepared)
        do { return (try await resources.start(), resources) }
        catch { resources.stop(); throw error }
    }

    nonisolated static func validate(_ prepared: Prepared) throws {
        guard prepared.runtime.state.isCurrent, let url = prepared.request.url,
              SourceRequestHeaderScope.origin(url) != nil, url.user == nil, url.password == nil,
              (prepared.request.httpMethod ?? "GET").uppercased() == "GET", prepared.request.httpBody == nil,
              (prepared.request.allHTTPHeaderFields ?? [:]).allSatisfy({ key, value in
                  !["host", "content-length", "transfer-encoding", "connection", "cookie", "range", "accept-encoding"].contains(key.lowercased())
                      && key.utf8.count <= 128 && value.utf8.count <= 8_192
              }) else { throw RSSWebFailure.resourceUnavailable }
    }
}

extension RSSStore {
    func mediaProgress(articleID: String, attachmentKey: String) -> RSSMediaProgress? {
        guard let article = article(id: articleID) else { return nil }
        let key = RSSIdentity.attachment(articleID: article.id, key: attachmentKey)
        return status(for: article.id)?.mediaProgress?[key]
    }
}
