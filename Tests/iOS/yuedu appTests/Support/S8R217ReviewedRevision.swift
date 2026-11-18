import Foundation
@testable import yuedu_app

/// 2026-11-18独立预审的公开站点改版规则；只用于隔离源维护验收，不改原包或生产解析器。
enum S8R217ReviewedRevision {
    static let imageURLHash = "8535542ba811779b05908f43a7e61a7cd59dbd9d311144cd355b18306dfa0538"

    static func applying(to source: RSSSource) -> RSSSource {
        var value = source
        value.ruleArticles = ".article-item"
        value.ruleTitle = ".article-item__title a@text"
        value.ruleLink = ".article-item__title a@href"
        value.ruleImage = "tag.img@src"
        return value
    }
}
