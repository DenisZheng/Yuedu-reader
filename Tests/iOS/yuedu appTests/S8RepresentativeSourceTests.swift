import CryptoKit
import Foundation
import XCTest
@testable import yuedu_app

private final class S8RequestMeter: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var transactionCount = 0
    private var statusCodes: [Int] = []
    private var requestMethods: [String] = []
    private var credentialHeadersSent = 0
    private var redirectsBlocked = 0
    private var transactionsOutsideExpectedOrigin = 0
    private let expectedOrigin: String?

    init(expectedOrigin: String? = nil) { self.expectedOrigin = expectedOrigin }

    static func origin(of url: URL?) -> String? {
        guard let url, let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(), let host = components.host?.lowercased() else { return nil }
        let port = components.port ?? (scheme == "https" ? 443 : scheme == "http" ? 80 : 0)
        return "\(scheme)://\(host):\(port)"
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        lock.lock()
        transactionCount += metrics.transactionMetrics.count
        statusCodes += metrics.transactionMetrics.compactMap { ($0.response as? HTTPURLResponse)?.statusCode }
        for transaction in metrics.transactionMetrics {
            requestMethods.append((transaction.request.httpMethod ?? "GET").uppercased())
            if let expectedOrigin, Self.origin(of: transaction.request.url) != expectedOrigin {
                transactionsOutsideExpectedOrigin += 1
            }
            let headers = transaction.request.allHTTPHeaderFields ?? [:]
            if headers.keys.contains(where: { ["cookie", "authorization", "proxy-authorization"].contains($0.lowercased()) }) {
                credentialHeadersSent += 1
            }
        }
        lock.unlock()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        lock.lock()
        redirectsBlocked += 1
        lock.unlock()
        completionHandler(nil)
    }

    func snapshot() -> (transactions: Int, statusCodes: [Int], requestMethods: [String], credentialHeadersSent: Int,
                        redirectsBlocked: Int, transactionsOutsideExpectedOrigin: Int) {
        lock.lock()
        defer { lock.unlock() }
        return (transactionCount, statusCodes, requestMethods, credentialHeadersSent, redirectsBlocked,
                transactionsOutsideExpectedOrigin)
    }
}

/// 仅执行固定包中单独预审的来源；普通抽查每项一次GET，完整RSS流程最多两页列表加一篇正文。
/// Cookie/凭据/缓存禁用，拒绝跳转；任何预审失败必须在发送请求之前抛出。
final class S8RepresentativeSourceTests: XCTestCase {
    private enum PreflightFailure: Error { case rejected }

    private func requirePreflight(_ condition: Bool, _ message: String) throws {
        guard condition else {
            XCTFail(message)
            throw PreflightFailure.rejected
        }
    }

    override func setUpWithError() throws { continueAfterFailure = false }
    @MainActor
    func testPreScreenedPublicXMLFeedUsesProductionFetcher() async throws {
        let source = try await source(at: 181)
        XCTAssertFalse(source.singleUrl)
        XCTAssertNil(source.ruleArticles)
        let (fetcher, session, meter) = makeFetcher()
        defer { session.invalidateAndCancel() }
        let started = ContinuousClock.now
        await fetcher.fetchItems(from: source, resolveEntry: false)
        let elapsed = Self.milliseconds(since: started)
        let request = meter.snapshot()
        XCTAssertTrue(fetcher.error == nil, "公开XML Feed请求应成功；错误文本与来源URL不进入测试输出")
        XCTAssertGreaterThan(fetcher.items.count, 0)
        XCTAssertEqual(request.transactions, 1, "该验收不得跟随跳转或发现额外地址")
        XCTAssertEqual(request.statusCodes, [200])
        XCTAssertEqual(request.requestMethods, ["GET"])
        XCTAssertEqual(request.credentialHeadersSent, 0)
        XCTAssertEqual(request.redirectsBlocked, 0)
        print("S8_REAL_SOURCE ordinal=181 kind=public-xml-feed requests=\(request.transactions) status=\(request.statusCodes.first ?? 0) parsedItems=\(fetcher.items.count) elapsedMs=\(elapsed) cookies=disabled credentials=none redirects=blocked")
    }

    @MainActor
    func testPreScreenedPublicHTMLMediaRuleListPage() async throws {
        let source = try await source(at: 265)
        XCTAssertFalse(source.singleUrl)
        XCTAssertNotNil(source.ruleArticles)
        XCTAssertTrue((source.ruleDescription ?? "").range(of: "<(video|source|iframe)\\b", options: .regularExpression.union(.caseInsensitive)) != nil,
                      "the selected public source must have the reviewed HTML-media rule shape")
        let (fetcher, session, meter) = makeFetcher()
        defer { session.invalidateAndCancel() }
        let started = ContinuousClock.now
        await fetcher.fetchItems(from: source, page: 1, resolveEntry: false)
        let elapsed = Self.milliseconds(since: started)
        let request = meter.snapshot()
        XCTAssertTrue(fetcher.error == nil, "公开HTML媒体列表请求应成功；错误文本与来源URL不进入测试输出")
        XCTAssertGreaterThan(fetcher.items.count, 0)
        let mediaItems = fetcher.items.filter {
            $0.contentHTML.range(of: "<(video|source|iframe)\\b", options: .regularExpression.union(.caseInsensitive)) != nil
        }.count
        XCTAssertGreaterThan(mediaItems, 0, "网页列表结果应保留至少一个已配置的HTML媒体片段")
        XCTAssertEqual(request.transactions, 1, "只读取一页，不请求文章或嵌入媒体地址")
        XCTAssertEqual(request.statusCodes, [200])
        XCTAssertEqual(request.requestMethods, ["GET"])
        XCTAssertEqual(request.credentialHeadersSent, 0)
        XCTAssertEqual(request.redirectsBlocked, 0)
        print("S8_REAL_SOURCE ordinal=265 kind=public-html-media-list requests=\(request.transactions) status=\(request.statusCodes.first ?? 0) parsedItems=\(fetcher.items.count) mediaMarkupItems=\(mediaItems) elapsedMs=\(elapsed) cookies=disabled credentials=none redirects=blocked articleAndEmbedRequests=0")
    }

    @MainActor
    func testPreScreenedPublicRuleListPageUsesProductionFetcher() async throws {
        let source = try await source(at: 14)
        try requirePreflight(!source.singleUrl && source.ruleArticles?.isEmpty == false
                             && source.ruleNextPage?.isEmpty == false,
                             "此实源验收仅允许只读规则列表")
        let entries = try await LegadoRSSScraper.resolveSortEntries(for: source)
        let entry = try XCTUnwrap(entries.first, "实源没有可用分类入口")
        try await validateFlowURL(entry.url, source: source)
        let root = URL.temporaryDirectory.appendingPathComponent("S8RealRulePaging-" + UUID().uuidString)
        let store = RSSStore(storageDirectory: root)
        store.addSource(source)
        try await store.flushPersistence()
        let (_, session, meter) = makeFetcher()
        defer {
            session.invalidateAndCancel()
            do { try FileManager.default.removeItem(at: root) }
            catch { XCTFail("无法清理隔离实源验收目录") }
        }
        try await validateFlowURL(source.url, source: source)
        let browser = RSSFeedSession(source: source, store: store, session: session,
                                     maxPages: 2, entries: entries)
        await browser.refresh(entry: entry)
        try requirePreflight(browser.error == nil && browser.currentPage == 1,
                             "实源第一页加载失败，停止后续请求")
        let firstPage = store.articles(for: source.id, scope: browser.scope)
        try requirePreflight(!firstPage.isEmpty && browser.nextURL != nil,
                             "实源第一页没有同时提供条目和下一页候选")
        let next = try XCTUnwrap(browser.nextURL)
        try await validateFlowURL(next.replacingOccurrences(of: "{{page}}", with: "2"), source: source)
        await browser.nextPage()
        try requirePreflight(browser.error == nil && browser.currentPage == 2,
                             "实源第二页加载失败，停止验证")

        let combined = store.articles(for: source.id, scope: browser.scope)
        let request = meter.snapshot()
        XCTAssertGreaterThan(combined.count, firstPage.count, "第二页应追加条目，而非只重复第一页")
        XCTAssertEqual(Set(combined.map(\.id)).count, combined.count)
        XCTAssertFalse(browser.canLoadMore, "实源抽查最多读取两页")
        XCTAssertEqual(request.transactions, 2)
        XCTAssertEqual(request.statusCodes, [200, 200])
        XCTAssertEqual(request.requestMethods, ["GET", "GET"])
        XCTAssertEqual(request.credentialHeadersSent, 0)
        XCTAssertEqual(request.redirectsBlocked, 0)
        try await store.flushPersistence()
        print("S8_REAL_SOURCE ordinal=14 kind=public-rule-list pages=2 requests=\(request.transactions) status=200,200 firstItems=\(firstPage.count) combinedItems=\(combined.count) cookies=preflight-empty credentials=none redirects=blocked")
    }

    @MainActor
    func testPreScreenedRSSPagingContentAndStateSurviveReload() async throws {
        var source = try await source(at: 146)
        try requirePreflight(!source.singleUrl && source.ruleContent?.isEmpty == false && source.nextContentUrl == nil,
                             "此流程只预审了普通规则正文，不允许自动追踪正文分页")
        source.newArticleNotificationsEnabled = false
        let entries = try await LegadoRSSScraper.resolveSortEntries(for: source)
        let entry = try XCTUnwrap(entries.first, "预审源没有分类入口")
        try await validateFlowURL(entry.url, source: source)

        let root = URL.temporaryDirectory.appendingPathComponent("S8RealRSSFlow-" + UUID().uuidString)
        let store = RSSStore(storageDirectory: root)
        store.addSource(source)
        try await store.flushPersistence()
        let (_, session, meter) = makeFetcher(expectedOrigin: try XCTUnwrap(Self.origin(of: source.sourceKey)))
        defer {
            session.invalidateAndCancel()
            do { try FileManager.default.removeItem(at: root) }
            catch { XCTFail("无法清理隔离实源验收目录") }
        }
        var completedPages = 0
        var contentCharacters = 0
        var stateReloaded = false
        defer {
            let audit = meter.snapshot()
            print("S8_REAL_FLOW_AUDIT ordinal=146 completedPages=\(completedPages) contentCharacters=\(contentCharacters) stateReloaded=\(stateReloaded) requests=\(audit.transactions) statuses=\(audit.statusCodes) credentialRequests=\(audit.credentialHeadersSent) redirects=\(audit.redirectsBlocked) crossOriginTransactions=\(audit.transactionsOutsideExpectedOrigin)")
        }
        let browser = RSSFeedSession(source: source, store: store, session: session, maxPages: 2, entries: entries)
        await browser.refresh(entry: entry)
        try requirePreflight(browser.error == nil && browser.currentPage == 1, "实源第一页加载失败，停止后续请求")
        completedPages = 1
        let firstPage = store.articles(for: source.id, scope: browser.scope)
        let article = try XCTUnwrap(firstPage.first, "实源第一页未得到条目")
        store.markRead(articleId: article.id, isRead: true)
        store.toggleFavorite(articleId: article.id)
        store.updateReaderScrollY(articleId: article.id, scrollY: 88)
        let next = try XCTUnwrap(browser.nextURL, "实源未产生下一页候选")
        try await validateFlowURL(next.replacingOccurrences(of: "{{page}}", with: "2"), source: source)
        await browser.nextPage()
        try requirePreflight(browser.error == nil && browser.currentPage == 2, "实源第二页加载失败，停止后续请求")
        completedPages = 2
        let combined = store.articles(for: source.id, scope: browser.scope)
        XCTAssertGreaterThan(combined.count, firstPage.count, "第二页应追加新条目，而非重复第一页")
        XCTAssertEqual(Set(combined.map(\.id)).count, combined.count)
        XCTAssertFalse(browser.canLoadMore, "实源抽查最多两页，不自动发第三页")
        let selected = try XCTUnwrap(store.article(id: article.id))
        XCTAssertTrue(selected.isRead && selected.isFavorite)
        try await validateFlowURL(selected.link, source: source)
        let complete = try await RSSArticleContentService.load(selected, source: source, store: store, session: session)
        XCTAssertTrue(complete)
        let loaded = try XCTUnwrap(store.article(id: article.id))
        XCTAssertGreaterThan(loaded.fullText?.count ?? 0, 80, "实际正文不能只是图片标签或空模板")
        XCTAssertFalse(loaded.fullTextHTML?.isEmpty ?? true)
        contentCharacters = loaded.fullText?.count ?? 0
        try await store.flushPersistence()
        let reloaded = RSSStore(storageDirectory: root)
        let recovered = try XCTUnwrap(reloaded.article(id: article.id))
        XCTAssertTrue(recovered.isRead && recovered.isFavorite)
        XCTAssertEqual(recovered.readerScrollY, 88)
        XCTAssertTrue(recovered.fullTextHTML == loaded.fullTextHTML, "重启后正文仍由同一个RSSStore恢复")
        XCTAssertEqual(reloaded.articles(for: source.id, scope: browser.scope).count, combined.count)
        stateReloaded = true

        let request = meter.snapshot()
        print("S8_REAL_FLOW_AUDIT ordinal=146 completedPages=\(completedPages) contentCharacters=\(contentCharacters) stateReloaded=\(stateReloaded) requests=\(request.transactions) statuses=\(request.statusCodes) methods=\(request.requestMethods) credentialRequests=\(request.credentialHeadersSent) redirects=\(request.redirectsBlocked)")
        XCTAssertGreaterThanOrEqual(request.transactions, 3, "两页列表和正文至少各需一次HTTP请求")
        XCTAssertLessThanOrEqual(request.transactions, 4, "预审流程预算上限为两页列表和一篇正文；最多容纳一次同源重定向记录")
        XCTAssertTrue(request.statusCodes.allSatisfy { (200..<300).contains($0) || $0 == 301 },
                      "只允许成功响应或单次记录到的301状态")
        XCTAssertLessThanOrEqual(request.statusCodes.filter { $0 == 301 }.count, 1,
                                 "受控RSS流程至多允许一个301事务")
        XCTAssertEqual(request.requestMethods, Array(repeating: "GET", count: request.transactions))
        XCTAssertEqual(request.credentialHeadersSent, 0)
        XCTAssertEqual(request.redirectsBlocked, 0)
        XCTAssertEqual(request.transactionsOutsideExpectedOrigin, 0,
                       "列表和正文的每次HTTP transaction必须留在预审源站origin")
        print("S8_REAL_FLOW ordinal=146 pages=2 items=\(combined.count) contentCharacters=\(loaded.fullText?.count ?? 0) requests=\(request.transactions) stateAndContentReloaded=true media=separate-scope")
    }

    @MainActor
    func testPreScreenedPublicImageSourceRulesParseSyntheticMatchingDOM() async throws {
        let source = try imageSourceFixture()
        let html = """
        <!doctype html><html><body>
          <article class="content">
            <h2><a href="/fixture/comic">S8 fixture comic</a></h2>
            <a href="/fixture/author">Fixture author</a>
            <p>Fixture summary label</p>
            <p>Fixture summary body</p>
            <img data-original="/fixture/cover.jpg" alt="Fixture cover">
          </article>
        </body></html>
        """
        let started = ContinuousClock.now
        let books = try await BookSourceParsingPipeline().parseSearchResults(
            html: html, baseURL: "https://s8-fixture.invalid/search", source: source)
        let elapsed = Self.milliseconds(since: started)
        XCTAssertEqual(books.count, 1, "源规则必须能解析匹配的本地合成条目DOM")
        let book = try XCTUnwrap(books.first)
        XCTAssertEqual(book.name, "S8 fixture comic")
        XCTAssertEqual(book.bookUrl, "https://s8-fixture.invalid/fixture/comic")
        XCTAssertFalse(book.coverUrl.isEmpty)
        XCTAssertTrue(book.intro.contains("Fixture summary"))
        print("S8_IMAGE_RULE_FIXTURE ordinal=122 parsed=\(books.count) linkResolved=true coverRulePresent=\(!book.coverUrl.isEmpty) elapsedMs=\(elapsed) networkRequests=0")
    }

    private func imageSourceFixture() throws -> BookSource {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("docs/Booksource.json"), options: .mappedIfSafe)
        try requirePreflight(SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                             == "3794d5f877d3369dc422145a1187f3dd5fe1f128486991b7fc95dc08de6ad9fc",
                             "离线合成解析仅适用于固定预审包")
        let rows = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        try requirePreflight(rows.count == 253, "固定书源包项数变化，停止解析")
        let candidate = try XCTUnwrap(rows.dropFirst(121).first)
        let one = try JSONSerialization.data(withJSONObject: [candidate], options: [.sortedKeys])
        let source = try XCTUnwrap(JSONDecoder().decode([BookSource].self, from: one).first)
        let serialized = String(decoding: one, as: UTF8.self).lowercased()
        try requirePreflight(source.bookSourceType == 2 && !source.searchUrl.isEmpty,
                             "此离线fixture只允许预审的图片书源搜索规则")
        try requirePreflight(source.header.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                             && source.loginUrl.isEmpty && source.loginUi.isEmpty && source.loginCheckJs.isEmpty
                             && source.jsLib.isEmpty && source.coverDecodeJs.isEmpty,
                             "图片源含认证或可执行脚本，不进入离线fixture")
        for marker in ["@js:", "<js>", "javascript:", "java.", "window.", "document."] {
            try requirePreflight(!serialized.contains(marker), "预审图片源含脚本特征")
        }
        return source
    }

    private func validateFlowURL(_ raw: String, source: RSSSource, sameOrigin: Bool = true) async throws {
        let parts = try XCTUnwrap(URLComponents(string: raw), "实源资源地址不可解析")
        let origin = try XCTUnwrap(URLComponents(string: source.sourceKey))
        try requirePreflight(parts.scheme?.lowercased() == "https" && parts.host != nil
                             && parts.user == nil && parts.password == nil, "实源目标不符合公开HTTPS读取条件")
        if sameOrigin {
            try requirePreflight(parts.host == origin.host && parts.port == origin.port,
                                 "未预审的跨站导航，拒绝继续请求")
        }
        let url = try XCTUnwrap(parts.url)
        try requirePreflight(CookieStore.shared.get(url: raw).isEmpty
                             && (HTTPCookieStorage.shared.cookies(for: url) ?? []).isEmpty,
                             "此目标已有持久Cookie，拒绝实源请求")
        let cookies = await WebViewCookieMirror.shared.cookies(for: parts.host ?? "")
        try requirePreflight(cookies.isEmpty, "此目标已有WebKit Cookie，拒绝实源请求")
    }

    func testPreScreenedPublicTextBookSourceSearch() async throws {
        let (source, requestURL) = try await bookSource(at: 2)
        XCTAssertEqual(source.bookSourceType, 0)
        XCTAssertTrue(source.header.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        XCTAssertTrue(source.loginUrl.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        XCTAssertTrue(source.loginUi.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        XCTAssertTrue(source.loginCheckJs.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        XCTAssertTrue(source.jsLib.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        XCTAssertFalse(source.searchUrl.isEmpty)
        XCTAssertEqual(requestURL.method.uppercased(), "GET")
        XCTAssertNil(requestURL.body)
        let resolvedSearchURL = RuleEngine.resolveURL(requestURL.url, base: source.cleanedBookSourceURL)
        guard let url = URL(string: resolvedSearchURL), let host = url.host else {
            XCTFail("已预审来源的搜索URL无法安全解析")
            return
        }
        XCTAssertEqual(url.scheme?.lowercased(), "https")
        XCTAssertNil(url.user)
        XCTAssertNil(url.password)
        XCTAssertNil(URLComponents(url: url, resolvingAgainstBaseURL: false)?.fragment)
        try requirePreflight(CookieStore.shared.get(url: url.absoluteString).isEmpty,
                             "此主机已有Legado持久Cookie，拒绝真实请求")
        try requirePreflight((HTTPCookieStorage.shared.cookies(for: url) ?? []).isEmpty,
                             "此主机已有URLSession Cookie，拒绝真实请求")
        let mirroredCookies = await WebViewCookieMirror.shared.cookies(for: host)
        try requirePreflight(mirroredCookies.isEmpty, "此主机已有WebKit Cookie，拒绝真实请求")

        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 25
        configuration.httpMaximumConnectionsPerHost = 1
        let meter = S8RequestMeter()
        let session = URLSession(configuration: configuration, delegate: meter, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let fetcher = BookSourceFetcher(webFetcher: WebFetcher(session: session))
        let query = "三体"
        SearchResultCache.shared.clear(query: query, source: source)
        defer { SearchResultCache.shared.clear(query: query, source: source) }
        let started = ContinuousClock.now
        let outcome = try await fetcher.searchOutcome(query: query, in: source,
                                                       failureMode: .propagateTransportError)
        let elapsed = Self.milliseconds(since: started)
        let request = meter.snapshot()
        XCTAssertGreaterThan(outcome.books.count, 0)
        XCTAssertEqual(request.transactions, 1, "只获取单次搜索页；不访问详情、目录或图片")
        XCTAssertEqual(request.statusCodes, [200])
        XCTAssertEqual(request.requestMethods, ["GET"])
        XCTAssertEqual(request.credentialHeadersSent, 0)
        XCTAssertEqual(request.redirectsBlocked, 0)
        print("S8_REAL_SOURCE ordinal=2 kind=public-text-book-search requests=\(request.transactions) status=\(request.statusCodes.first ?? 0) results=\(outcome.books.count) elapsedMs=\(elapsed) cookies=preflight-empty credentials=none redirects=blocked detailTocAndCoverRequests=0")
    }

    private func bookSource(at ordinal: Int) async throws -> (BookSource, (url: String, method: String, body: String?, pageVariables: [String: String]?)) {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("docs/Booksource.json"), options: .mappedIfSafe)
        try requirePreflight(SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                             == "3794d5f877d3369dc422145a1187f3dd5fe1f128486991b7fc95dc08de6ad9fc",
                             "真实源抽查仅适用于静态审计过的固定包")
        let rows = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        try requirePreflight(rows.count == 253 && ordinal == 2, "未预审的书源条目，拒绝联网")
        let one = try JSONSerialization.data(withJSONObject: [rows[ordinal - 1]], options: [.sortedKeys])
        let decoded = try XCTUnwrap(JSONDecoder().decode([BookSource].self, from: one).first)
        let serialized = String(decoding: one, as: UTF8.self).lowercased()
        for marker in ["@js:", "<js>", "javascript:", "window.location", "document.cookie", "java.connect", "downloadfile"] {
            try requirePreflight(!serialized.contains(marker), "预审来源含潜在脚本或副作用特征，停止联网")
        }
        for method in ["post", "put", "patch", "delete"] {
            try requirePreflight(!serialized.contains("\"method\":\"\(method)\""), "预审来源含非只读方法，停止联网")
        }
        let components = try XCTUnwrap(URLComponents(string: decoded.bookSourceUrl))
        XCTAssertEqual(components.scheme?.lowercased(), "https")
        XCTAssertNil(components.user)
        XCTAssertNil(components.password)
        XCTAssertNil(components.query)
        XCTAssertNil(components.fragment)
        let search = await decoded.renderSearchURL(query: "三体", page: 1)
        return (decoded, search)
    }

    private func source(at ordinal: Int) async throws -> RSSSource {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let url = root.appendingPathComponent("docs/rssSources-valid.json")
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        try requirePreflight(SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                             == "0e30301c85fb511961be7542212ee63b8d4173a9b6c33bb5a4f88eb6d3795f45",
                             "实源抽查仅适用已经静态审计过的固定包")
        let rows = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        try requirePreflight(rows.count == 307 && [14, 146, 181, 265].contains(ordinal),
                             "未预审的RSS条目，拒绝联网")
        let raw = rows[ordinal - 1]
        let candidateData = try JSONSerialization.data(withJSONObject: [raw], options: [.sortedKeys])
        let loaded = try await RSSImportService.load(.data(candidateData))
        XCTAssertEqual(loaded.requests, 0, "读取配置本身不请求网络或执行规则")
        let source = try XCTUnwrap(loaded.candidates.first?.source)
        XCTAssertEqual(loaded.candidates.count, 1)
        XCTAssertTrue(loaded.candidates.first?.issue == nil)
        try requirePreflight([source.header, source.loginUrl, source.loginUi, source.loginCheckJs,
                              source.jsLib, source.injectJs, source.preloadJs, source.variable]
            .allSatisfy { $0?.isEmpty != false }, "源含认证或脚本配置，拒绝联网")
        let parts = try XCTUnwrap(URLComponents(string: source.url))
        XCTAssertEqual(parts.scheme?.lowercased(), "https")
        XCTAssertNil(parts.user)
        XCTAssertNil(parts.password)
        XCTAssertNil(parts.query)
        XCTAssertNil(parts.fragment)

        // Refuse to execute either rules or linked navigation from any candidate with script markers.
        let serialized = String(decoding: candidateData, as: UTF8.self)
        let lowercased = serialized.lowercased()
        for marker in ["@js:", "<js>", "javascript:", "java.", "window.location", "document.cookie"] {
            try requirePreflight(!lowercased.contains(marker), "预审源包含脚本特征，停止网络验收")
        }
        for method in ["post", "put", "delete", "patch"] {
            try requirePreflight(!lowercased.contains("\"method\":\"\(method)\""), "预审源包含非只读方法，停止网络验收")
        }
        return source
    }

    @MainActor
    private func makeFetcher(expectedOrigin: String? = nil) -> (RSSFetcher, URLSession, S8RequestMeter) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 25
        configuration.httpMaximumConnectionsPerHost = 1
        let meter = S8RequestMeter(expectedOrigin: expectedOrigin)
        let session = URLSession(configuration: configuration, delegate: meter, delegateQueue: nil)
        return (RSSFetcher(session: session), session, meter)
    }

    private static func origin(of raw: String) -> String? {
        guard let url = URL(string: raw) else { return nil }
        return S8RequestMeter.origin(of: url)
    }

    private static func milliseconds(since start: ContinuousClock.Instant) -> Int {
        let duration = start.duration(to: .now).components
        return Int(duration.seconds * 1_000 + duration.attoseconds / 1_000_000_000_000_000)
    }
}
