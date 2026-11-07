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
        var rule = source.ruleArticles?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !rule.isEmpty else { throw ScraperError.invalidRule("ruleArticles") }
        let reverse = rule.hasPrefix("-")
        if reverse { rule.removeFirst() }
        let listRule = rule
        let runtime = try await RSSRuntime.make(source: source, owner: owner, requestSession: requestSession)
        return try await runtime.run { host in
            let response = try await host.fetchRulePage(ruleURL: normalizedRequestURL(entry?.url ?? source.sourceKey), page: page, isPrimaryRequest: true)
            guard (200..<300).contains(response.status) else { throw ScraperError.httpStatus(response.status) }
            try Task.checkCancellation()
            return try await host.run { bridge in
                try parseArticles(body: response.body, finalURL: response.url, listRule: listRule, reverse: reverse,
                                  source: source, bridge: bridge, variables: response.variables,
                                  scope: entry.map(RSSArticleScope.category) ?? .feed, sortName: entry?.name ?? "",
                                  requestURL: response.requestURL)
            }
        }
    }

    /// 一条解析路径，固定输入测试也走同一个共享bridge，不另造无状态JSContext。
    static func parseArticles(body: String, finalURL: String, listRule: String, reverse: Bool,
                              source: RSSSource, bridge: ModernParserBridge, variables: [String: String] = [:],
                              scope: RSSArticleScope = .feed, sortName: String = "", requestURL: String? = nil) throws -> [RSSItem] {
        return try SourcePerfTrace.span("rss.rules.list", "main=\(Thread.isMainThread) bytes=\(body.utf8.count)") { () throws -> [RSSItem] in
        let page = RuleData()
        page.variableMap = variables
        let baseURL = requestURL ?? finalURL
        let elements = try bridge.withRuleContext(content: body, baseURL: baseURL, scope: page, redirectURL: finalURL, stage: "rss.list") {
            $0.getElements(ruleStr: listRule)
        }
        guard !elements.isEmpty else { throw ScraperError.noArticlesFound }
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
                var html = description
                if !image.isEmpty { html = "<img src=\"\(image)\" style=\"max-width:100%;height:auto;margin-bottom:1em;\" />" + html }
                var item = RSSItem(id: link.isEmpty ? finalTitle : link, title: finalTitle, link: link, pubDate: date,
                                   description: description.isEmpty ? "" : RSSContentSanitizer.summary(from: description),
                                   contentHTML: html, imageURL: image.isEmpty ? nil : image, sourceId: source.id)
                    .identified(sourceID: source.id, scope: scope)
                item.variables = row.variableMap
                item.categoryName = sortName.isEmpty ? nil : sortName
                return item
            }
            if let item { items.append(item) }
        }
        if reverse { items.reverse() }
        guard !items.isEmpty else { throw ScraperError.noArticlesFound }
        return items
        }
    }

    static func fetchArticleContent(source: RSSSource, articleLink: String, owner: RSSStore? = nil,
                                    variables: [String: String] = [:], categoryName: String = "", articleTitle: String = "",
                                    requestSession: URLSession = LegadoJSBridge.requestSession) async throws -> String? {
        let rule = source.ruleContent?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !rule.isEmpty else { return nil }
        let runtime = try await RSSRuntime.make(source: source, owner: owner, requestSession: requestSession)
        return try await runtime.run { host in
            let response = try await host.fetchRulePage(ruleURL: normalizedRequestURL(articleLink), variables: variables)
            guard (200..<300).contains(response.status) else { throw ScraperError.httpStatus(response.status) }
            try Task.checkCancellation()
            return try await host.run { bridge in
                let data = RuleData()
                data.variableMap = response.variables
                let article = RSSArticleScriptObject(source: source, sortName: categoryName, data: data)
                article.link = articleLink
                article.title = articleTitle
                let html = try bridge.withRuleContext(content: response.body, baseURL: response.requestURL, scope: data,
                                                     redirectURL: response.url, bindings: ["rssArticle": article], stage: "rss.content") {
                    $0.getString(ruleStr: rule)
                }
                return html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : html
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
    case invalidURL, invalidRule(String), httpError, httpStatus(Int), encodingError, noArticlesFound, atsBlocked, scriptFailure, interactionRequired, runtimeStateUnavailable, executionTimedOut
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
        }
    }
}
