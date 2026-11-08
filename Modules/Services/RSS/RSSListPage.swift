import Foundation

/// 一次列表请求的值快照；分页控制者只提交成功的页，不从View或全局缓存猜下一页。
struct RSSListPage: Sendable {
    var items: [RSSItem]
    var nextURL: String?
    var requestURL: String
    var finalURL: String
    var variables: [String: String]
    var scope: RSSArticleScope
}
