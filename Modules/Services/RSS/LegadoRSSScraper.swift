import Foundation

/// RSS只提供源/流程/文章上下文；与书源共用同一会话、AnalyzeUrl、请求和规则引擎。
enum LegadoRSSScraper {
    static func resolveSortEntries(for source: RSSSource, owner: RSSStore? = nil,
                                   requestSession: URLSession = LegadoJSBridge.requestSession) async throws -> [RSSSortEntry] {
        let raw = source.sortUrl?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard LegadoSortURLParser.needsJSEvaluation(raw) else {
            return LegadoSortURLParser.entries(from: raw, fallbackURL: source.sourceKey)
        }
        let runtime = try await RSSRuntime.make(source: source, owner: owner, requestSession: requestSession)
        return try await runtime.run { host in
            try await host.run { bridge in
                let value = try bridge.withRuleContext(content: "", baseURL: source.sourceKey, scope: nil, stage: "rss.categories") {
                    $0.getString(ruleStr: "@js:" + (LegadoSortURLParser.jsBody(raw) ?? ""))
                }
                return LegadoSortURLParser.entries(from: value, fallbackURL: source.sourceKey)
            }
        }
    }

    static func scrape(source: RSSSource, entry: RSSSortEntry? = nil, page: Int = 1, owner: RSSStore? = nil,
                       requestSession: URLSession = LegadoJSBridge.requestSession) async throws -> [RSSItem] {
        try await fetchListPage(source: source, entry: entry, page: page, owner: owner, requestSession: requestSession).items
    }

    static func fetchListPage(source: RSSSource, entry: RSSSortEntry? = nil, page: Int = 1, key: String? = nil,
                              requestURL: String? = nil, owner: RSSStore? = nil,
                              requestSession: URLSession = LegadoJSBridge.requestSession) async throws -> RSSListPage {
        var rule = source.ruleArticles?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !rule.isEmpty else { throw ScraperError.invalidRule("ruleArticles") }
        let reverse = rule.hasPrefix("-")
        if reverse { rule.removeFirst() }
        let listRule = rule
        let target = requestURL ?? (key == nil ? entry?.url ?? source.sourceKey : source.searchUrl ?? "")
        guard !target.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ScraperError.invalidURL }
        let scope = key.map(RSSArticleScope.search) ?? entry.map(RSSArticleScope.category) ?? .feed
        let runtime = try await RSSRuntime.make(source: source, owner: owner, requestSession: requestSession)
        return try await runtime.run { host in
            let response = try await host.fetchRulePage(ruleURL: normalizedRequestURL(target), key: key, page: page, isPrimaryRequest: true)
            guard (200..<300).contains(response.status) else { throw ScraperError.httpStatus(response.status) }
            try Task.checkCancellation()
            return try await host.run { bridge in
                try parseListPage(body: response.body, finalURL: response.url, listRule: listRule, reverse: reverse,
                                  source: source, bridge: bridge, variables: response.variables,
                                  scope: scope, sortName: entry?.name ?? key ?? "",
                                  requestURL: response.requestURL, ruleURL: target)
            }
        }
    }

    /// 一条解析路径，固定输入测试也走同一个共享bridge，不另造无状态JSContext。
    static func parseArticles(body: String, finalURL: String, listRule: String, reverse: Bool,
                              source: RSSSource, bridge: ModernParserBridge, variables: [String: String] = [:],
                              scope: RSSArticleScope = .feed, sortName: String = "", requestURL: String? = nil) throws -> [RSSItem] {
        try parseListPage(body: body, finalURL: finalURL, listRule: listRule, reverse: reverse,
                          source: source, bridge: bridge, variables: variables, scope: scope,
                          sortName: sortName, requestURL: requestURL ?? finalURL, ruleURL: requestURL ?? finalURL).items
    }

    private static func parseListPage(body: String, finalURL: String, listRule: String, reverse: Bool,
                                     source: RSSSource, bridge: ModernParserBridge, variables: [String: String],
                                     scope: RSSArticleScope, sortName: String, requestURL: String, ruleURL: String) throws -> RSSListPage {
        return try SourcePerfTrace.span("rss.rules.list", "main=\(Thread.isMainThread) bytes=\(body.utf8.count)") { () throws -> RSSListPage in
        guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ScraperError.httpError }
        let page = RuleData()
        page.variableMap = variables
        let baseURL = requestURL
        var nextURL: String?
        let elements = try bridge.withRuleContext(content: body, baseURL: baseURL, scope: page, redirectURL: finalURL, stage: "rss.list") { engine in
            let elements = engine.getElements(ruleStr: listRule)
            let nextRule = source.ruleNextPage?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if nextRule.uppercased() == "PAGE" { nextURL = ruleURL }
            else if !nextRule.isEmpty {
                // 列表next以本次请求地址为基址；文章链接仍使用真实redirectURL。
                _ = engine.setRedirectUrl(baseURL)
                let raw = engine.getString(ruleStr: nextRule).trimmingCharacters(in: .whitespacesAndNewlines)
                if !raw.isEmpty { nextURL = engine.resolveURL(raw) }
                _ = engine.setRedirectUrl(finalURL)
            }
            return elements
        }
        var items: [RSSItem] = []
        items.reserveCapacity(elements.count)
        for element in elements {
            let row = RuleData()
            row.variableMap = page.variableMap
            let article = RSSArticleScriptObject(source: source, sortName: sortName, data: row, isListItem: true)
            let item = try bridge.withRuleContext(content: element, baseURL: baseURL, scope: row,
                                                  redirectURL: finalURL, bindings: ["rssArticle": article], stage: "rss.article") { engine -> RSSItem? in
                let title = RSSContentSanitizer.cleanText(engine.getString(ruleStr: source.ruleTitle))
                article.title = title
                let date = parseDate(engine.getString(ruleStr: source.rulePubDate))
                let description = (source.ruleDescription ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? "" : engine.getString(ruleStr: source.ruleDescription)
                let image = engine.getOptionalURL(ruleStr: source.ruleImage)
                let link = engine.getString(ruleStr: source.ruleLink, isUrl: true).trimmingCharacters(in: .whitespacesAndNewlines)
                article.link = link
                let finalTitle = RSSContentSanitizer.cleanText(article.title)
                guard !finalTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
                var item = RSSItem(id: link.isEmpty ? finalTitle : link, title: finalTitle, link: link, pubDate: date,
                                   description: description.isEmpty ? "" : RSSContentSanitizer.summary(from: description),
                                   contentHTML: description, imageURL: image.isEmpty ? nil : image, sourceId: source.id)
                    .identified(sourceID: source.id, scope: scope)
                item.contentType = source.contentType ?? .web
                item.variables = row.variableMap
                item.categoryName = sortName.isEmpty ? nil : sortName
                return item
            }
            if let item { items.append(item) }
        }
        if reverse { items.reverse() }
        return RSSListPage(items: items, nextURL: nextURL, requestURL: requestURL,
                           finalURL: finalURL, variables: page.variableMap, scope: scope)
        }
    }

    static func fetchArticleContent(source: RSSSource, articleLink: String, owner: RSSStore? = nil,
                                    variables: [String: String] = [:], categoryName: String = "", articleTitle: String = "",
                                    requestSession: URLSession = LegadoJSBridge.requestSession) async throws -> String? {
        let value = try await fetchArticleContentResult(source: source, articleLink: articleLink, owner: owner,
            variables: variables, categoryName: categoryName, articleTitle: articleTitle, requestSession: requestSession)
        guard !value.isPartial else { throw ScraperError.contentIncomplete }
        return value.html.isEmpty ? nil : value.html
    }

    static func fetchArticleContentResult(source: RSSSource, articleLink: String, owner: RSSStore? = nil,
                                          variables: [String: String] = [:], categoryName: String = "", articleTitle: String = "",
                                          articleType: RSSContentType? = nil, maxPages: Int = 50,
                                          requestSession: URLSession = LegadoJSBridge.requestSession) async throws -> RSSContentResult {
        let rule = source.ruleContent?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !rule.isEmpty else { return .init(html: "", variables: variables, pageCount: 0, stop: .complete) }
        let runtime = try await RSSRuntime.make(source: source, owner: owner, requestSession: requestSession)
        return try await runtime.run { host in
            let textPages = (source.contentType ?? .web) == .web && (articleType ?? source.contentType ?? .web) == .web
            let first = try await contentPage(host: host, source: source, link: articleLink, rule: rule, variables: variables,
                categoryName: categoryName, articleTitle: articleTitle, getNext: textPages)
            var parts = [first.content]
            var currentVariables = first.variables
            var visited: Set<String> = [articleLink, first.finalURL]
            var bodies: Set<String> = [RSSIdentity.digest([first.content])]
            var pending = first.nextURLs
            // Android：首个结果为多链接则逐链接合并，不再追它们的nextContentUrl；单链接顺序追踪。
            let multiple = pending.count > 1
            var stop: RSSContentResult.Stop = .complete
            var totalBytes = first.content.utf8.count
            while !pending.isEmpty {
                try Task.checkCancellation()
                guard parts.count < max(1, maxPages), totalBytes < 8 * 1024 * 1024 else { stop = .budget; break }
                let next = pending.removeFirst()
                guard visited.insert(next).inserted else { stop = .loop; if multiple { continue }; break }
                do {
                    let page = try await contentPage(host: host, source: source, link: next, rule: rule,
                        variables: multiple ? first.variables : currentVariables, categoryName: categoryName,
                        articleTitle: articleTitle, getNext: !multiple)
                    if page.finalURL != next, visited.contains(page.finalURL) { stop = .loop; if multiple { continue }; break }
                    visited.insert(page.finalURL)
                    guard bodies.insert(RSSIdentity.digest([page.content])).inserted else {
                        stop = .duplicate; if multiple { continue }; break
                    }
                    guard totalBytes + page.content.utf8.count <= 8 * 1024 * 1024 else { stop = .budget; break }
                    parts.append(page.content)
                    totalBytes += page.content.utf8.count
                    currentVariables = page.variables
                    if !multiple { pending = Array(page.nextURLs.prefix(1)) }
                } catch is CancellationError { throw CancellationError() }
                catch let requirement as SourceRuntimeRequirement { throw requirement }
                catch {
                    // 原始失败保留诊断类型，不记录私密请求/正文；已得到的页作为部分结果交回owner。
                    AppLogger.parse("RSS content pagination failed", context: ["stage": "rss.content", "count": parts.count], level: .warning)
                    stop = .failed
                    break
                }
            }
            return RSSContentResult(html: parts.joined(separator: "\n"), variables: currentVariables, pageCount: parts.count, stop: stop)
        }
    }

    private struct ContentPage: Sendable {
        var content: String
        var nextURLs: [String]
        var finalURL: String
        var variables: [String: String]
    }

    private static func contentPage(host: SourceScriptHost<ModernParserBridge>, source: RSSSource, link: String,
                                    rule: String, variables: [String: String], categoryName: String,
                                    articleTitle: String, getNext: Bool) async throws -> ContentPage {
        let response = try await host.fetchRulePage(ruleURL: normalizedRequestURL(link), variables: variables)
        guard (200..<300).contains(response.status) else { throw ScraperError.httpStatus(response.status) }
        try Task.checkCancellation()
        return try await host.run { bridge in
            let data = RuleData()
            data.variableMap = response.variables
            let article = RSSArticleScriptObject(source: source, sortName: categoryName, data: data)
            article.link = link
            article.title = articleTitle
            return try bridge.withRuleContext(content: response.body, baseURL: response.requestURL, scope: data,
                                               redirectURL: response.url, bindings: ["rssArticle": article], stage: "rss.content") { engine in
                let content = engine.getString(ruleStr: rule)
                let next = getNext ? engine.getStringList(ruleStr: source.nextContentUrl, isUrl: true) : []
                return ContentPage(content: content, nextURLs: next.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty },
                                   finalURL: response.url, variables: data.variableMap)
            }
        }
    }

    /// 只补缺失的scheme，不剥离模板、fragment或URL options，也不强制HTTP升级。
    static func normalizedRequestURL(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return trimmed }
        let lower = trimmed.lowercased()
        if lower.hasPrefix("http://") || lower.hasPrefix("https://") || lower.hasPrefix("data:")
            || trimmed.hasPrefix("//") || trimmed.hasPrefix("/")
            || trimmed.hasPrefix("<js>") || lower.hasPrefix("@js:") || trimmed.hasPrefix("{{") {
            return trimmed
        }
        let beforeSlash = trimmed.split(separator: "/", maxSplits: 1).first ?? ""
        let head = beforeSlash.split(separator: ",", maxSplits: 1).first ?? ""
        if head.contains("."), !head.contains(" ") { return "https://" + trimmed }
        return trimmed
    }

    private static let dateFormatters: [DateFormatter] = {
        ["EEE, dd MMM yyyy HH:mm:ss Z", "EEE, dd MMM yyyy HH:mm:ss zzz", "EEE, d MMM yyyy HH:mm:ss Z",
         "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd HH:mm", "yyyy-MM-dd'T'HH:mm:ssZ", "yyyy-MM-dd'T'HH:mm:ss.SSSZ",
         "yyyy-MM-dd'T'HH:mm:ssXXXXX", "yyyy-MM-dd'T'HH:mm:ss.SSSXXXXX", "yyyy-MM-dd", "yyyy/MM/dd HH:mm:ss",
         "yyyy/MM/dd", "MM-dd HH:mm", "MM/dd/yyyy", "dd/MM/yyyy"].map { format in
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = format
            return formatter
        }
    }()

    private static func parseDate(_ string: String) -> Date? {
        let value = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        for formatter in dateFormatters { if let date = formatter.date(from: value) { return date } }
        if let epoch = Double(value) {
            if epoch > 1_000_000_000_000 { return Date(timeIntervalSince1970: epoch / 1000) }
            if epoch > 1_000_000_000 { return Date(timeIntervalSince1970: epoch) }
        }
        return nil
    }
}

enum ScraperError: LocalizedError {
    case invalidURL, invalidRule(String), httpError, httpStatus(Int), encodingError, noArticlesFound, atsBlocked, scriptFailure, interactionRequired, runtimeStateUnavailable, executionTimedOut, contentIncomplete
    var errorDescription: String? {
        switch self {
        case .invalidURL: localized("RSS URL 無效")
        case .invalidRule(let name): String(format: localized("規則 %@ 格式無效"), name)
        case .httpError: localized("HTTP 請求失敗")
        case .httpStatus(let status): String(format: localized("RSS 請求失敗：HTTP %d"), status)
        case .encodingError: localized("網頁編碼錯誤")
        case .noArticlesFound: localized("沒有找到文章")
        case .atsBlocked: localized("此來源使用不安全的 HTTP 連線，已被 iOS 安全政策阻擋。")
        case .scriptFailure: localized("RSS 源腳本執行失敗，請查看診斷")
        case .interactionRequired: localized("此 RSS 來源需要前台網頁或登入驗證")
        case .runtimeStateUnavailable: localized("RSS 執行狀態無法讀取，已停止執行來源")
        case .executionTimedOut: localized("RSS 來源執行逾時")
        case .contentIncomplete: localized("正文尚未完整載入，已保留部分內容")
        }
    }
}
