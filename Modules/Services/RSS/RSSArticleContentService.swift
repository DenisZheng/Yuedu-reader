import Foundation

/// 内容选择与写回的唯一用例。普通Feed保持安全全文提取，显式规则内容不使用长度启发式。
@MainActor
enum RSSArticleContentService {
    static func usesRules(_ source: RSSSource?) -> Bool {
        guard let source else { return false }
        return source.isLegadoRuleBased || source.ruleContent?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    static func needsOriginalPage(_ article: RSSArticleRecord, source: RSSSource?) -> Bool {
        usesRules(source) && !prefersDescription(article, source: source)
            && source?.ruleContent?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false
    }

    static func prefersDescription(_ article: RSSArticleRecord, source: RSSSource?) -> Bool {
        if usesRules(source) { return !article.contentHTML.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        return RSSArticleHTMLSanitizer.hasSubstantialStructuredContent(article.contentHTML, fallbackText: article.summary)
    }

    /// 部分结果持久化但不会标为全文完成；显式重试可以重新进入同一个用例。
    @discardableResult
    static func load(_ article: RSSArticleRecord, source: RSSSource?, store: RSSStore,
                     session: URLSession = LegadoJSBridge.requestSession) async throws -> Bool {
        guard !prefersDescription(article, source: source) else { return true }
        guard let ticket = store.requestTicket(for: article.sourceId) else { throw CancellationError() }
        if let source, usesRules(source) {
            guard source.ruleContent?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else { return true }
            let result = try await LegadoRSSScraper.fetchArticleContentResult(source: source, articleLink: article.link,
                owner: store, variables: article.variables ?? [:], categoryName: article.categoryName ?? "", articleTitle: article.title,
                articleType: article.contentType, requestSession: session)
            try Task.checkCancellation()
            guard store.accepts(ticket), store.article(id: article.id) != nil else { throw CancellationError() }
            let text = await SourceScriptThread.run { RSSContentSanitizer.cleanText(result.html) }
            try Task.checkCancellation()
            guard store.accepts(ticket), store.article(id: article.id) != nil else { throw CancellationError() }
            store.updateFullText(articleId: article.id, text: text, html: result.html,
                                 isPartial: result.isPartial, variables: result.variables)
            return !result.isPartial
        }
        let extracted = try await RSSArticleContentLoader.loadFullText(for: article)
        try Task.checkCancellation()
        guard store.accepts(ticket), store.article(id: article.id) != nil else { throw CancellationError() }
        store.updateFullText(articleId: article.id, text: extracted.text, html: extracted.html)
        return true
    }
}
