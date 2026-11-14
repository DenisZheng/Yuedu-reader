import CryptoKit
import Foundation
import AVFoundation
import SwiftSoup
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
    let boundary: S8RequestBoundary?

    init(expectedOrigin: String? = nil, boundary: S8RequestBoundary? = nil) {
        self.expectedOrigin = expectedOrigin; self.boundary = boundary
    }

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

private enum PreflightFailure: Error { case rejected }

// 固定包静态加载也会离开MainActor，预审失败不依赖XCTestCase实例。
private func requirePreflight(_ condition: Bool, _ message: String) throws {
    guard condition else {
        XCTFail(message)
        throw PreflightFailure.rejected
    }
}

/// 仅执行固定包中单独预审的来源；完整RSS流程最多两页列表加一篇正文，图片另限一张。
/// Cookie/凭据/缓存禁用；确切URL（或已预审canonical URL的哈希）与准入预算在HTTP分派前校验。
final class S8RepresentativeSourceTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        try requirePreflight(RSSPoCTestHost.isEnabled, "实源S8验收必须使用Reader-Fork-RSS-PoC隔离宿主，禁止主页后台请求")
    }
    @MainActor
    func testPreScreenedPublicXMLFeedUsesProductionFetcher() async throws {
        let source = try await source(at: 181)
        XCTAssertFalse(source.singleUrl)
        XCTAssertNil(source.ruleArticles)
        let (fetcher, session, meter) = try makeFetcher(urls: [source.url])
        defer { session.invalidateAndCancel(); meter.boundary?.close() }
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
        XCTAssertTrue(source.enableJs && source.loadWithBaseUrl,
                      "R265是允许JS和baseURL的规则网页；静态预审不得暗中改配置再称网页兼容")
        XCTAssertTrue((source.ruleDescription ?? "").range(of: "<(video|source|iframe)\\b", options: .regularExpression.union(.caseInsensitive)) != nil,
                      "the selected public source must have the reviewed HTML-media rule shape")
        let (fetcher, session, meter) = try makeFetcher(urls: [source.url])
        defer { session.invalidateAndCancel(); meter.boundary?.close() }
        let started = ContinuousClock.now
        await fetcher.fetchItems(from: source, page: 1, resolveEntry: false)
        let elapsed = Self.milliseconds(since: started)
        let request = meter.snapshot()
        XCTAssertTrue(fetcher.error == nil, "公开HTML媒体列表请求应成功；错误文本与来源URL不进入测试输出")
        XCTAssertGreaterThan(fetcher.items.count, 0)
        let articles = fetcher.items
        do {
        let audit = try await SourceScriptThread.run {
            try requirePreflight(articles.count <= 120, "R265首页超出原100项预审范围，不解析或加载更多")
            guard let base = URL(string: source.url) else { throw PreflightFailure.rejected }
            var mediaItems = 0, iframe = 0, directMedia = 0, scriptNodes = 0
            var crossOrigin = 0, withQuery = 0, invalid = 0, embeddedCredentials = 0
            var hostHashes: Set<String> = []
            var inspectedBytes = 0
            for item in articles {
                inspectedBytes += item.contentHTML.utf8.count
                try requirePreflight(inspectedBytes <= 4 * 1_024 * 1_024, "R265列表HTML超出静态预审上限")
                let document = try SwiftSoup.parse(item.contentHTML)
                scriptNodes += try document.select("script,link[rel=preload]").count
                let nodes = try document.select("iframe[src],video[src],audio[src],source[src]")
                if !nodes.isEmpty() { mediaItems += 1 }
                for node in nodes {
                    let kind = node.tagName().lowercased()
                    if kind == "iframe" { iframe += 1 } else { directMedia += 1 }
                    let raw = try node.attr("src")
                    guard let target = URL(string: raw, relativeTo: base)?.absoluteURL,
                          target.scheme?.lowercased() == "https", target.host != nil else {
                        invalid += 1; continue
                    }
                    hostHashes.insert(Self.hostDigest(target))
                    if target.host?.lowercased() != base.host?.lowercased() || target.port != base.port {
                        crossOrigin += 1
                    }
                    if target.query != nil { withQuery += 1 }
                    if target.user != nil || target.password != nil { embeddedCredentials += 1 }
                }
            }
            return (mediaItems, iframe, directMedia, scriptNodes, crossOrigin, withQuery,
                    invalid, embeddedCredentials, hostHashes.sorted())
        }
        XCTAssertGreaterThan(audit.0, 0, "网页列表结果应保留至少一个已配置的HTML媒体片段")
        try requirePreflight(audit.0 == articles.count && audit.1 == articles.count && audit.2 == 0
                             && audit.3 == 0 && audit.4 == audit.1 && audit.5 == audit.1
                             && audit.6 == 0 && audit.7 == 0
                             && audit.8 == ["3688965aa49195bc7a92c9ad2308fdda03f77fc27ebcbe019a4ddb065269c284"],
                             "R265网页结构或iframe目标变化，旧预审结论失效；不自动进入子页面")
        XCTAssertEqual(request.transactions, 1, "只读取一页，不请求文章或嵌入媒体地址")
        XCTAssertEqual(request.statusCodes, [200])
        XCTAssertEqual(request.requestMethods, ["GET"])
        XCTAssertEqual(request.credentialHeadersSent, 0)
        XCTAssertEqual(request.redirectsBlocked, 0)
        print("S8_REAL_SOURCE ordinal=265 kind=public-html-media-list requests=\(request.transactions) status=\(request.statusCodes.first ?? 0) parsedItems=\(articles.count) mediaMarkupItems=\(audit.0) iframe=\(audit.1) directMedia=\(audit.2) scriptNodes=\(audit.3) crossOrigin=\(audit.4) queryTargets=\(audit.5) invalidTargets=\(audit.6) embeddedCredentials=\(audit.7) hostHashes=\(audit.8) elapsedMs=\(elapsed) cookies=disabled credentials=none redirects=blocked articleAndEmbedRequests=0")
        } catch {
            if error is PreflightFailure { throw error }
            XCTFail("R265静态HTML审阅失败；不输出网页、资源URL或原始异常")
            throw PreflightFailure.rejected
        }
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
        let (_, session, meter) = try makeFetcher(urls: [entry.url.replacingOccurrences(of: "{{page}}", with: "1")], maximumRequests: 2)
        defer {
            session.invalidateAndCancel(); meter.boundary?.close()
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
        let approvedNext = next.replacingOccurrences(of: "{{page}}", with: "2")
        try await validateFlowURL(approvedNext, source: source)
        meter.boundary?.admit(try XCTUnwrap(URL(string: approvedNext)))
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
    func testPreScreenedPublicRSSImageCandidateListHasBoundedTargets() async throws {
        var source = try await source(at: 217)
        source.newArticleNotificationsEnabled = false
        try requirePreflight(source.importedFromLegado == true && source.contentType == .web
                             && !source.singleUrl && !source.enabledCookieJar
                             && source.header?.isEmpty != false && source.loginUrl?.isEmpty != false
                             && source.loginUi?.isEmpty != false && source.loginCheckJs?.isEmpty != false
                             && source.jsLib?.isEmpty != false && source.injectJs?.isEmpty != false
                             && source.preloadJs?.isEmpty != false && source.startJs?.isEmpty != false
                             && source.coverDecodeJs?.isEmpty != false && source.shouldOverrideUrlLoading?.isEmpty != false
                             && source.ruleArticles?.isEmpty == false && source.ruleImage?.isEmpty == false,
                             "R217候选必须保持已审查的公开规则列表与图片配置")
        for rule in [source.sortUrl, source.ruleArticles, source.ruleTitle, source.ruleLink,
                     source.ruleDescription, source.ruleImage, source.ruleNextPage].compactMap({ $0 }) {
            let lowercased = rule.lowercased()
            try requirePreflight(!["@js:", "<js>", "javascript:", "java.", "window.", "document."]
                .contains(where: { lowercased.contains($0) }), "R217规则出现可执行脚本特征，停止请求")
        }
        let sourceURL = try XCTUnwrap(URL(string: source.url))
        let sourceHostHash = Self.hostDigest(sourceURL)
        try requirePreflight(sourceHostHash == "2dc6f9c67021d2176e91781b8ceb91631cddce143307cdad49c9d8448fcc5f5d",
                             "R217源身份超出静态审阅范围")
        let entries = try await LegadoRSSScraper.resolveSortEntries(for: source)
        try requirePreflight(entries.count == 7, "R217分类结构变化，停止候选页预审")
        let entry = try XCTUnwrap(entries.first)
        try await validateFlowURL(entry.url, source: source)
        let target = try XCTUnwrap(URL(string: entry.url))
        try requirePreflight(Self.hostDigest(target) == "2dc6f9c67021d2176e91781b8ceb91631cddce143307cdad49c9d8448fcc5f5d"
                             && target.host == sourceURL.host && target.query == nil && target.fragment == nil,
                             "R217首个列表目标超出静态审阅范围")

        let root = URL.temporaryDirectory.appendingPathComponent("S8RSSCrossOriginImageCandidate-" + UUID().uuidString)
        let store = RSSStore(storageDirectory: root)
        store.addSource(source)
        try await store.flushPersistence()
        let (_, session, meter) = try makeFetcher(urls: [entry.url], maximumRequests: 2,
                                                  expectedOrigin: Self.origin(of: entry.url))
        defer {
            session.invalidateAndCancel(); meter.boundary?.close()
            do { try FileManager.default.removeItem(at: root) }
            catch { XCTFail("无法清理隔离候选源目录") }
        }
        let browser = RSSFeedSession(source: source, store: store, session: session,
                                     maxPages: 1, entries: entries)
        let started = ContinuousClock.now
        await browser.refresh(entry: entry)
        let elapsed = Self.milliseconds(since: started)
        try requirePreflight(browser.error == nil && browser.currentPage == 1,
                             "R217受限首列表加载失败；不跟随重定向或重试")
        let articles = store.articles(for: source.id, scope: browser.scope)
        try requirePreflight(!articles.isEmpty && articles.count <= 120,
                             "R217列表结果为空或超出120条预审范围")
        do {
            let audit = try await SourceScriptThread.run {
                var inspectedBytes = 0, imageItems = 0, queryTargets = 0, fragments = 0
                var invalidTargets = 0, credentials = 0
                var uniqueImages: Set<String> = [], hostHashes: Set<String> = [], extensions: Set<String> = []
                for article in articles {
                    inspectedBytes += article.contentHTML.utf8.count
                    try requirePreflight(inspectedBytes <= 4 * 1_024 * 1_024,
                                         "R217条目标记超出静态审阅4MiB上限")
                    guard let raw = article.imageURL, !raw.isEmpty else { continue }
                    imageItems += 1
                    uniqueImages.insert(raw)
                    guard let url = URL(string: raw), let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
                          parts.scheme?.lowercased() == "https", let host = parts.host else {
                        invalidTargets += 1; continue
                    }
                    hostHashes.insert(SHA256.hash(data: Data(host.lowercased().utf8))
                        .map { String(format: "%02x", $0) }.joined())
                    if parts.query != nil { queryTargets += 1 }
                    if parts.fragment != nil { fragments += 1 }
                    if parts.user != nil || parts.password != nil { credentials += 1 }
                    let ext = url.pathExtension.lowercased()
                    if !ext.isEmpty { extensions.insert(ext) }
                }
                return (inspectedBytes, imageItems, uniqueImages.count, hostHashes.sorted(), queryTargets,
                        fragments, invalidTargets, credentials, extensions.sorted())
            }
            try requirePreflight(audit.0 == 0 && audit.1 == 18 && audit.2 == 17
                                 && audit.3 == ["0336c9b73661988775e65e74fb5b8a891afe86e13bbf4b226c25b51e440860b1"]
                                 && audit.4 == 0 && audit.5 == 0 && audit.6 == 0 && audit.7 == 0
                                 && audit.8 == ["png", "webp"],
                                 "R217列表图片形状变化，停止资源请求并重新预审")
            guard let article = articles.first(where: { $0.imageURL?.isEmpty == false }),
                  let raw = article.imageURL else { throw PreflightFailure.rejected }
            try await validateFlowURL(raw, source: source, sameOrigin: false)
            let imageURL = try XCTUnwrap(URL(string: raw))
            let imageURLHash = SHA256.hash(data: Data(imageURL.absoluteString.utf8))
                .map { String(format: "%02x", $0) }.joined()
            try requirePreflight(Self.hostDigest(imageURL) == "0336c9b73661988775e65e74fb5b8a891afe86e13bbf4b226c25b51e440860b1"
                                 && imageURLHash == "a8dfb32af7f036c216fc9d3222840cf2ee9a078675b6ff5e7c98f35ac02c5aef"
                                 && imageURL.scheme?.lowercased() == "https" && imageURL.user == nil
                                 && imageURL.password == nil && imageURL.query == nil && imageURL.fragment == nil
                                 && imageURL.pathExtension.lowercased() == "webp",
                                 "首张图片超出已预审的精确公开HTTPS WebP目标，拒绝请求")
            meter.boundary?.admit(imageURL)
            let image: RSSImageService.Image
            do {
                image = try await RSSImageService.load(raw, source: source, baseURL: URL(string: article.link),
                    context: nil, owner: store, session: session)
            } catch {
                let failure = error as NSError
                let kind = failure.domain == NSURLErrorDomain ? "url" : failure.domain == "S8RequestBoundary" ? "boundary" : "other"
                print("S8_REAL_IMAGE_FAILURE ordinal=217 domain=\(kind) code=\(failure.code)")
                XCTFail("预审图片生产请求失败；不输出URL、响应或任意错误文本")
                throw PreflightFailure.rejected
            }
            XCTAssertEqual(image.url, imageURL, "不允许图片请求跟随未预审跳转")
            try await validateFlowURL(raw, source: source, sameOrigin: false)
            XCTAssertEqual(image.mime, "image/webp")
            XCTAssertGreaterThan(image.data.count, 0)
            let displayed = try await RSSImageService.displayImage(image.data)
            XCTAssertGreaterThan(displayed.size.width, 0)
            XCTAssertGreaterThan(displayed.size.height, 0)
            store.markRead(articleId: article.id, isRead: true)
            store.toggleFavorite(articleId: article.id)
            try await store.flushPersistence()
            let reloaded = RSSStore(storageDirectory: root)
            let recovered = try XCTUnwrap(reloaded.article(id: article.id))
            XCTAssertTrue(recovered.isRead && recovered.isFavorite)
            XCTAssertEqual(recovered.imageURL, article.imageURL)
            let request = meter.snapshot()
            XCTAssertEqual(request.transactions, 2)
            XCTAssertEqual(request.statusCodes, [200, 200])
            XCTAssertEqual(request.requestMethods, ["GET", "GET"])
            XCTAssertEqual(request.credentialHeadersSent, 0)
            XCTAssertEqual(request.redirectsBlocked, 0)
            XCTAssertEqual(request.transactionsOutsideExpectedOrigin, 1)
            XCTAssertFalse(browser.canLoadMore, "只读一页和一张已预审图片")
            print("S8_REAL_IMAGE ordinal=217 pages=1 requests=\(request.transactions) status=200,200 parsedItems=\(articles.count) imageMime=\(image.mime) bytes=\(image.data.count) decodedWidth=\(Int(displayed.size.width)) decodedHeight=\(Int(displayed.size.height)) outsideOriginRequests=\(request.transactionsOutsideExpectedOrigin) cookies=disabled credentials=none redirects=blocked savedReadFavorite=imageURL-reloaded imageRequests=1")
        } catch {
            if error is PreflightFailure { throw error }
            XCTFail("R217图片目标静态审阅失败；不输出网页、图片URL或原始异常")
            throw PreflightFailure.rejected
        }
    }

    @MainActor
    func testPreScreenedPublicRSSImageCandidateListHasBoundedImageTargets() async throws {
        var source = try await source(at: 128)
        source.newArticleNotificationsEnabled = false
        try requirePreflight(source.importedFromLegado == true && source.contentType == .web && !source.singleUrl
                             && source.ruleArticles?.isEmpty == false
                             && source.ruleImage?.isEmpty == false
                             && source.enableJs && source.loadWithBaseUrl,
                             "R128候选必须保持已审查的规则列表与文章图片配置")
        let entries = try await LegadoRSSScraper.resolveSortEntries(for: source)
        try requirePreflight(entries.count == 7, "R128分类结构变化，停止候选页预审")
        let entry = try XCTUnwrap(entries.first)
        try await validateFlowURL(entry.url, source: source)
        let target = try XCTUnwrap(URL(string: entry.url))
        let targetHostHash = SHA256.hash(data: Data((target.host ?? "").lowercased().utf8))
            .map { String(format: "%02x", $0) }.joined()
        try requirePreflight(targetHostHash == "abcedd09ff356f680355277f62c7971de112b5b37cf4b25626ec5a4ee88b1a8c"
                             && target.query == nil && target.fragment == nil,
                             "R128首个列表目标超出离线预审范围")

        let root = URL.temporaryDirectory.appendingPathComponent("S8RSSImageCandidate-" + UUID().uuidString)
        let store = RSSStore(storageDirectory: root)
        store.addSource(source)
        try await store.flushPersistence()
        let (_, session, meter) = try makeFetcher(urls: [entry.url], maximumRequests: 1,
                                                  expectedOrigin: Self.origin(of: entry.url))
        defer {
            session.invalidateAndCancel(); meter.boundary?.close()
            do { try FileManager.default.removeItem(at: root) }
            catch { XCTFail("无法清理隔离候选源目录") }
        }
        let browser = RSSFeedSession(source: source, store: store, session: session,
                                     maxPages: 1, entries: entries)
        let started = ContinuousClock.now
        await browser.refresh(entry: entry)
        let elapsed = Self.milliseconds(since: started)
        try requirePreflight(browser.error == nil && browser.currentPage == 1,
                             "R128受限首列表加载失败；不跟随重定向或重试")
        let articles = store.articles(for: source.id, scope: browser.scope)
        try requirePreflight(!articles.isEmpty && articles.count <= 120,
                             "R128列表结果为空或超出120条预审范围")

        do {
            let audit = try await SourceScriptThread.run {
                var inspectedBytes = 0
                var imageItems = 0
                var uniqueImages: Set<String> = []
                var hostHashes: Set<String> = []
                var queryTargets = 0, fragments = 0, invalidTargets = 0, credentials = 0
                var extensions: Set<String> = []
                for article in articles {
                    inspectedBytes += article.contentHTML.utf8.count
                    try requirePreflight(inspectedBytes <= 4 * 1_024 * 1_024,
                                         "R128文章标记超出静态审阅4MiB上限")
                    guard let raw = article.imageURL, !raw.isEmpty else { continue }
                    imageItems += 1
                    uniqueImages.insert(raw)
                    guard let url = URL(string: raw), let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
                          parts.scheme?.lowercased() == "https", let host = parts.host else {
                        invalidTargets += 1; continue
                    }
                    hostHashes.insert(SHA256.hash(data: Data(host.lowercased().utf8))
                        .map { String(format: "%02x", $0) }.joined())
                    if parts.query != nil { queryTargets += 1 }
                    if parts.fragment != nil { fragments += 1 }
                    if parts.user != nil || parts.password != nil { credentials += 1 }
                    let ext = url.pathExtension.lowercased()
                    if !ext.isEmpty { extensions.insert(ext) }
                }
                return (inspectedBytes, imageItems, uniqueImages.count, hostHashes.sorted(),
                        queryTargets, fragments, invalidTargets, credentials, extensions.sorted())
            }
            try requirePreflight(audit.1 == 0 && audit.2 == 0 && audit.3.isEmpty
                                 && audit.4 == 0 && audit.5 == 0 && audit.6 == 0 && audit.7 == 0,
                                 "R128首列表的无图片形状变化，停止自动扩展资源请求")
            let request = meter.snapshot()
            XCTAssertEqual(request.transactions, 1)
            XCTAssertEqual(request.statusCodes, [200])
            XCTAssertEqual(request.requestMethods, ["GET"])
            XCTAssertEqual(request.credentialHeadersSent, 0)
            XCTAssertEqual(request.redirectsBlocked, 0)
            XCTAssertEqual(request.transactionsOutsideExpectedOrigin, 0)
            XCTAssertFalse(browser.canLoadMore, "仅读取首列表，不自动翻页")
            print("S8_REAL_SOURCE ordinal=128 kind=public-rss-image-target-preflight requests=\(request.transactions) status=200 parsedItems=\(articles.count) inspectedHtmlBytes=\(audit.0) imageItems=\(audit.1) uniqueImages=\(audit.2) imageHostHashes=\(audit.3) queryTargets=\(audit.4) fragments=\(audit.5) invalidHTTPS=\(audit.6) embeddedCredentials=\(audit.7) extensions=\(audit.8) elapsedMs=\(elapsed) cookies=disabled credentials=none redirects=blocked imageRequests=0 pages=1 nextStep=no-image-target")
        } catch {
            if error is PreflightFailure { throw error }
            XCTFail("R128图片目标静态审阅失败；不输出网页、图片URL或原始异常")
            throw PreflightFailure.rejected
        }
    }

    @MainActor
    func testPreScreenedRSSListImageDecodesAndStateReloads() async throws {
        var source = try await source(at: 14)
        source.newArticleNotificationsEnabled = false
        let entries = try await LegadoRSSScraper.resolveSortEntries(for: source)
        let entry = try XCTUnwrap(entries.first)
        let initial = entry.url.replacingOccurrences(of: "{{page}}", with: "1")
        try await validateFlowURL(initial, source: source)
        let root = URL.temporaryDirectory.appendingPathComponent("S8RealRSSImage-" + UUID().uuidString)
        let store = RSSStore(storageDirectory: root)
        store.addSource(source)
        let (_, session, meter) = try makeFetcher(urls: [initial], maximumRequests: 2)
        defer {
            session.invalidateAndCancel(); meter.boundary?.close()
            do { try FileManager.default.removeItem(at: root) }
            catch { XCTFail("无法清理隔离图片验收目录") }
        }
        let browser = RSSFeedSession(source: source, store: store, session: session, maxPages: 1, entries: entries)
        await browser.refresh(entry: entry)
        try requirePreflight(browser.error == nil && browser.currentPage == 1,
                             "预审列表加载失败，停止图片请求")
        let article = try XCTUnwrap(store.articles(for: source.id, scope: browser.scope).first)
        let raw = try XCTUnwrap(article.imageURL)
        try await validateFlowURL(raw, source: source, sameOrigin: false)
        let url = try XCTUnwrap(URL(string: raw))
        let hostHash = SHA256.hash(data: Data((url.host ?? "").lowercased().utf8)).map { String(format: "%02x", $0) }.joined()
        try requirePreflight(hostHash == "83882f81fef7e323604ad0ba933feca98add378f8ebf4875c4e65cef4169b87f"
                             && url.query == nil && url.fragment == nil && url.pathExtension.lowercased() == "jpg",
                             "图片目标不在预审的公开HTTPS CDN范围，拒绝请求")
        meter.boundary?.admit(url)
        let image: RSSImageService.Image
        do {
            image = try await RSSImageService.load(raw, source: source, baseURL: URL(string: article.link),
                context: nil, owner: store, session: session)
        } catch {
            let failure = error as NSError
            print("S8_REAL_IMAGE_FAILURE ordinal=14 domain=\(failure.domain == NSURLErrorDomain ? "url" : "other") code=\(failure.code)")
            XCTFail("预审图片加载失败；不输出URL、响应或任意错误文本")
            throw PreflightFailure.rejected
        }
        XCTAssertTrue(image.url == url, "不允许图片请求跟随未预审跳转")
        XCTAssertEqual(image.mime, "image/jpeg")
        XCTAssertGreaterThan(image.data.count, 0)
        let displayed = try await RSSImageService.displayImage(image.data)
        XCTAssertGreaterThan(displayed.size.width, 0)
        XCTAssertGreaterThan(displayed.size.height, 0)
        store.markRead(articleId: article.id, isRead: true)
        store.toggleFavorite(articleId: article.id)
        try await store.flushPersistence()
        let reloaded = RSSStore(storageDirectory: root)
        let recovered = try XCTUnwrap(reloaded.article(id: article.id))
        XCTAssertTrue(recovered.isRead && recovered.isFavorite)
        XCTAssertTrue(recovered.imageURL == article.imageURL)
        let request = meter.snapshot()
        XCTAssertEqual(request.transactions, 2)
        XCTAssertEqual(request.statusCodes, [200, 200])
        XCTAssertEqual(request.requestMethods, ["GET", "GET"])
        XCTAssertEqual(request.credentialHeadersSent, 0)
        XCTAssertEqual(meter.boundary?.counts.rejected, 0)
        print("S8_REAL_IMAGE ordinal=14 requests=\(request.transactions) statuses=\(request.statusCodes) decodedBytes=\(image.data.count) width=\(Int(displayed.size.width)) height=\(Int(displayed.size.height)) stateReloaded=true credentials=none boundaryRejected=0")
    }

    @MainActor
    func testPreScreenedRSSPagingContentAndStateSurviveReload() async throws {
        try await reviewedR146Flow(inspectImage: false)
    }

    @MainActor
    func testReviewedR146ImageRequiresSystemTrustAndNativeDecode() async throws {
        try await reviewedR146Flow(inspectImage: true)
    }

    @MainActor
    private func reviewedR146Flow(inspectImage: Bool) async throws {
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
        let initial = entry.url.replacingOccurrences(of: "{{page}}", with: "1")
        // 2026-11-13无Cookie/禁跟随301预审：只准入该固定HTTPS同源canonical目标，不公开完整私有源地址。
        // 系统可能对重定向重复询问canInit；5次准入是发出前硬上限，最终HTTP事务仍须≤4。
        let (_, session, meter) = try makeFetcher(urls: [initial], maximumRequests: 5,
            expectedOrigin: try XCTUnwrap(Self.origin(of: source.sourceKey)),
            approvedURLHashes: ["4402893f281dbad6741d597002e66e5cb950bded42eb0f2b4ab1faf0ac914deb"])
        defer {
            session.invalidateAndCancel(); meter.boundary?.close()
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
        let approvedNext = next.replacingOccurrences(of: "{{page}}", with: "2")
        try await validateFlowURL(approvedNext, source: source)
        meter.boundary?.admit(try XCTUnwrap(URL(string: approvedNext)))
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
        meter.boundary?.admit(try XCTUnwrap(URL(string: selected.link)))
        let complete = try await RSSArticleContentService.load(selected, source: source, store: store, session: session)
        XCTAssertTrue(complete)
        let loaded = try XCTUnwrap(store.article(id: article.id))
        XCTAssertGreaterThan(loaded.fullText?.count ?? 0, 80, "实际正文不能只是图片标签或空模板")
        XCTAssertFalse(loaded.fullTextHTML?.isEmpty ?? true)
        contentCharacters = loaded.fullText?.count ?? 0
        // 只审阅首张图片的准入元数据，不从正文自动发出资源请求。
        let imageURL = try await SourceScriptThread.run {
            let document = try SwiftSoup.parse(loaded.fullTextHTML ?? "")
            guard let raw = try document.select("img[src]").first()?.attr("src") else { return Optional<URL>.none }
            return URL(string: raw, relativeTo: URL(string: loaded.link))?.absoluteURL
        }
        if let imageURL {
            let targetHash = SHA256.hash(data: Data(imageURL.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined()
            print("S8_R146_IMAGE_TARGET hostHash=\(Self.hostDigest(imageURL)) targetHash=\(targetHash) https=\(imageURL.scheme == "https") query=\(imageURL.query != nil) fragment=\(imageURL.fragment != nil) embeddedCredentials=\(imageURL.user != nil || imageURL.password != nil) extension=\(Set(["jpg", "jpeg", "png", "webp", "gif"]).contains(imageURL.pathExtension.lowercased())) requested=false")
        }
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
        if inspectImage {
            let target = try XCTUnwrap(imageURL, "当前正文没有可审阅图片，停止")
            let hash = SHA256.hash(data: Data(target.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined()
            try requirePreflight(hash == "bbc03c1f647ed0bf32a695e7bf73ab031a018dc9b6d1d140490e6d5211f872aa"
                                 && target.scheme == "https" && target.query == nil && target.fragment == nil
                                 && target.user == nil && target.password == nil,
                                 "图片目标不再是2026-11-14单独预审的确切地址，禁止继续")
            try await validateFlowURL(target.absoluteString, source: source, sameOrigin: false)
            // 列表/正文已经结束；新边界只准入一个精确图片GET，总HTTP事务最多4+1。
            meter.boundary?.close()
            let (_, imageSession, imageMeter) = try makeFetcher(urls: [target.absoluteString], maximumRequests: 1)
            defer { imageSession.invalidateAndCancel(); imageMeter.boundary?.close() }
            do {
                let image = try await RSSImageService.load(target.absoluteString, source: source,
                    baseURL: URL(string: loaded.link), context: nil, owner: store, session: imageSession)
                let decoded = try await RSSImageService.displayImage(image.data)
                XCTAssertGreaterThan(decoded.size.width, 0)
                XCTAssertGreaterThan(decoded.size.height, 0)
                let audit = imageMeter.snapshot()
                XCTAssertEqual(audit.transactions, 1)
                XCTAssertEqual(audit.statusCodes, [200])
                XCTAssertEqual(audit.credentialHeadersSent, 0)
                XCTAssertEqual(imageMeter.boundary?.counts.rejected, 0)
                print("S8_R146_IMAGE_DECODED requests=1 status=200 bytes=\(image.data.count) credentials=none")
            } catch {
                let failure = error as NSError
                let domain = failure.domain == NSURLErrorDomain ? "url" : "other"
                let code = (-1206 ... -1200).contains(failure.code) ? String(failure.code) : "other"
                let sslCode = S8TLSFailureMetadata.sslCode(failure)
                let audit = imageMeter.snapshot()
                print("S8_R146_IMAGE_TRUST_FAILURE domain=\(domain) code=\(code) sslCode=\(sslCode) requests=\(audit.transactions) statuses=\(audit.statusCodes) rejected=\(imageMeter.boundary?.counts.rejected ?? -1) credentials=\(audit.credentialHeadersSent)")
                XCTFail("R146图片未通过系统TLS/读取/原生解码；不放宽校验，不自动重试")
                throw PreflightFailure.rejected
            }
        }
    }

    func testReviewedAudioCatalogPolicyRejectsParameterAndOriginChanges() async throws {
        let source = try await source(at: 141)
        let entries = try await LegadoRSSScraper.resolveSortEntries(for: source)
        let entry = try XCTUnwrap(entries.first)
        let policy = try reviewedAudioCatalogPolicy(entry.url, source: source)
        let rendered = entry.url.replacingOccurrences(of: "{{(page-1)*20}}", with: "0")
            .replacingOccurrences(of: "{{Date.now()}}", with: String(Int64(Date().timeIntervalSince1970 * 1_000)))
        let parts = try XCTUnwrap(URLComponents(string: rendered))
        XCTAssertTrue(policy(try XCTUnwrap(parts.url)))
        let template = try XCTUnwrap(URLComponents(string: entry.url)?.queryItems)
        let offset = try XCTUnwrap(template.first { $0.value == "{{(page-1)*20}}" }?.name)
        let time = try XCTUnwrap(template.first { $0.value == "{{Date.now()}}" }?.name)
        let fixed = try XCTUnwrap(template.first { $0.name != offset && $0.name != time }?.name)
        for (name, value) in [(offset, "20"), (time, "1"), (fixed, "s8-changed")] {
            var altered = parts
            altered.queryItems = parts.queryItems?.map { $0.name == name ? URLQueryItem(name: name, value: value) : $0 }
            XCTAssertFalse(policy(try XCTUnwrap(altered.url)), "不能准入第二页、过期时间或其他静态参数变更")
        }
        var altered = parts
        altered.queryItems?.append(URLQueryItem(name: "s8-extra", value: "1"))
        XCTAssertFalse(policy(try XCTUnwrap(altered.url)))
        altered = parts; altered.host = "outside-fixture.invalid"
        XCTAssertFalse(policy(try XCTUnwrap(altered.url)))
        altered = parts; altered.path += "/unreviewed"
        XCTAssertFalse(policy(try XCTUnwrap(altered.url)))
    }

    /// R141仍是type=0网页；本项证明真实规则提取和原生媒体资源层，不冒充原网页/iframe播放验收。
    @MainActor
    func testPreScreenedRSSAudioResourceAdvancesAndProgressReloads() async throws {
        var source = try await source(at: 141)
        try requirePreflight(!source.singleUrl && source.nextContentUrl == nil,
                             "音频抽查不允许动态网页入口或自动正文分页")
        source.newArticleNotificationsEnabled = false
        try await validateFlowURL(source.url, source: source)
        let entries = try await LegadoRSSScraper.resolveSortEntries(for: source)
        let entry = try XCTUnwrap(entries.first)
        try await validateFlowURL(entry.url, source: source)
        let root = URL.temporaryDirectory.appendingPathComponent("S8RealRSSAudio-" + UUID().uuidString)
        let store = RSSStore(storageDirectory: root)
        store.addSource(source)
        try await store.flushPersistence()
        let catalogPolicy = try reviewedAudioCatalogPolicy(entry.url, source: source)
        let (_, session, meter) = try makeFetcher(urls: [], maximumRequests: 8, allowsHead: true, approvedDynamicURL: catalogPolicy)
        defer {
            session.invalidateAndCancel(); meter.boundary?.close()
            do { try FileManager.default.removeItem(at: root) }
            catch { XCTFail("无法清理隔离音频验收目录") }
        }
        do {
            let browser = RSSFeedSession(source: source, store: store, session: session, maxPages: 1, entries: entries)
            await browser.refresh(entry: entry)
            try requirePreflight(browser.error == nil && browser.currentPage == 1,
                                 "预审音频源目录失败，停止后续请求")
            let articles = store.articles(for: source.id, scope: browser.scope)
            // Store可按日期重排；只选择元数据同时满足已预审正文/音频主机的条目，不自动访问其他外链。
            let eligible: [RSSArticleRecord] = articles.filter(Self.hasReviewedAudioTargets)
            print("S8_AUDIO_CATALOG_AUDIT items=\(articles.count) eligible=\(eligible.count) audioVariables=\(articles.filter { $0.variables?["audio"]?.isEmpty == false }.count)")
            let article = try XCTUnwrap(eligible.first, "当前目录没有同时满足预审正文和MP3元数据的条目，停止外链请求")
            let audioRaw = try XCTUnwrap(article.variables?["audio"], "列表@put必须将音频目标保留在该条目变量")
            let articleURL = try await reviewedMediaURL(article.link, source: source,
                hostHash: "2dcc4a7798b9474d6edf5bc8b3f043e74a890a1cdcf3ac5b7ed0688e537d4201")
            let audioURL = try await reviewedMediaURL(audioRaw, source: source,
                hostHash: "482c8af1bfc1e58de41b5777a3452b6b4ac3f8ff4e4d77f5bfd75a14791b5d2e")
            try requirePreflight(audioURL.pathExtension.lowercased() == "mp3", "只预审了公开MP3资源")
            meter.boundary?.admit(articleURL)
            meter.boundary?.admit(audioURL)
            let complete = try await RSSArticleContentService.load(article, source: source, store: store, session: session)
            try requirePreflight(complete, "真实规则正文未完整取得")
            let loaded = try XCTUnwrap(store.article(id: article.id))
            let html = try XCTUnwrap(loaded.fullTextHTML)
            let htmlAudio = try await SourceScriptThread.run {
                try SwiftSoup.parse(html).select("audio[src]").first()?.attr("src")
            }
            try requirePreflight(htmlAudio == audioRaw, "正文java.get必须读取原条目audio变量，不串到其他条目")

            let initial = try await RSSMediaRequestService.prepare(audioRaw, source: source, base: articleURL,
                context: nil, owner: store, trustedRuleURL: false)
            // 使用现有Prepared的注入点；请求构造/资源图/播放器不变，上游仅走本项受保护Session。
            let runtime = try await RSSRuntime.make(source: source, owner: store, requestSession: session)
            let prepared = RSSMediaRequestService.Prepared(request: initial.request, context: initial.context, runtime: runtime)
            let (stream, resources) = try await RSSMediaRequestService.stream(prepared)
            defer { resources.stop() }
            XCTAssertTrue(stream.headers.isEmpty, "AVPlayer不持有源凭据")
            let controller = VideoPlaybackController(rss: store, articleID: article.id, attachmentKey: "primary",
                stream: stream, title: "S8 real audio resource", resources: resources)
            defer { controller.close() }
            let advanced = XCTestExpectation(description: "真实MP3经生产资源层推进0.5秒")
            let observer = controller.player.addBoundaryTimeObserver(
                forTimes: [NSValue(time: CMTime(seconds: 0.5, preferredTimescale: 600))], queue: .main) { advanced.fulfill() }
            defer { controller.player.removeTimeObserver(observer) }
            controller.start()
            let result = await XCTWaiter.fulfillment(of: [advanced], timeout: 15)
            if result != .completed {
                let audit = meter.snapshot()
                let itemStatus = controller.player.currentItem?.status.rawValue ?? -1
                let clock = controller.player.currentTime().seconds
                let safeClock = clock.isFinite ? String(format: "%.3f", clock) : "nonfinite"
                print("S8_AUDIO_NO_ADVANCE requests=\(audit.transactions) statuses=\(audit.statusCodes) rejected=\(meter.boundary?.counts.rejected ?? -1) itemStatus=\(itemStatus) timeControl=\(controller.player.timeControlStatus.rawValue) clock=\(safeClock)")
            }
            try requirePreflight(result == .completed, "真实MP3在有限等待内未推进，不能把HTTP成功当播放成功")
            let position = controller.player.currentTime().seconds
            XCTAssertGreaterThan(position, 0.4)
            controller.close()
            XCTAssertTrue(resources.isStopped)
            try await store.flushPersistence()
            let reloaded = RSSStore(storageDirectory: root)
            let progress = try XCTUnwrap(reloaded.mediaProgress(articleID: article.id, attachmentKey: "primary"))
            XCTAssertGreaterThan(progress.position, 0.4)
            let recovered = try XCTUnwrap(reloaded.article(id: article.id))
            XCTAssertTrue(recovered.variables?["audio"] == audioRaw && recovered.contentType == article.contentType)
            let audit = meter.snapshot()
            XCTAssertGreaterThanOrEqual(audit.transactions, 3)
            XCTAssertLessThanOrEqual(audit.transactions, 8)
            XCTAssertTrue(audit.statusCodes.allSatisfy { [200, 206].contains($0) })
            XCTAssertTrue(audit.statusCodes.contains(206), "预审MP3应实际使用Range响应")
            XCTAssertTrue(audit.requestMethods.allSatisfy { ["GET", "HEAD"].contains($0) })
            XCTAssertEqual(audit.credentialHeadersSent, 0)
            XCTAssertEqual(meter.boundary?.counts.rejected, 0)
            print("S8_REAL_AUDIO ordinal=141 items=\(articles.count) requests=\(audit.transactions) statuses=\(audit.statusCodes) advancedMs=\(Int(position * 1_000)) progressReloaded=true resourcesStopped=true credentials=none originalWebPagePlayback=unverified")
        } catch {
            try await store.flushPersistence()
            if error is PreflightFailure { throw error }
            let value = error as NSError
            let kind = value.domain == NSURLErrorDomain ? "url" : value.domain == "S8RequestBoundary" ? "boundary" : "other"
            print("S8_REAL_AUDIO_FAILURE ordinal=141 domain=\(kind) code=\(value.code) requests=\(meter.snapshot().transactions)")
            XCTFail("真实音频流程失败；不输出URL、响应正文或任意错误文本")
            throw PreflightFailure.rejected
        }
    }

    private static func hostDigest(_ url: URL) -> String {
        SHA256.hash(data: Data((url.host ?? "").lowercased().utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func hasReviewedAudioTargets(_ item: RSSArticleRecord) -> Bool {
        guard let raw = item.variables?["audio"], let audio = URL(string: raw), let article = URL(string: item.link) else { return false }
        for url in [audio, article] {
            guard url.scheme == "https", url.query == nil, url.fragment == nil, url.user == nil, url.password == nil else { return false }
        }
        guard audio.pathExtension.lowercased() == "mp3" else { return false }
        let mediaMatches = hostDigest(audio) == "482c8af1bfc1e58de41b5777a3452b6b4ac3f8ff4e4d77f5bfd75a14791b5d2e"
        let articleMatches = hostDigest(article) == "2dcc4a7798b9474d6edf5bc8b3f043e74a890a1cdcf3ac5b7ed0688e537d4201"
        return mediaMatches && articleMatches
    }

    /// 只准入R141首页的已审查纯表达式：page=1的offset为0，时间参数限本次25秒窗口。
    /// 其他query项、origin和path全部逐项相等，不删参数或冻结源脚本来适配白名单。
    private func reviewedAudioCatalogPolicy(_ template: String, source: RSSSource) throws -> @Sendable (URL) -> Bool {
        let parts = try XCTUnwrap(URLComponents(string: template))
        let query = try XCTUnwrap(parts.queryItems)
        let offset = try XCTUnwrap(query.first { $0.value == "{{(page-1)*20}}" }?.name)
        let timestamp = try XCTUnwrap(query.first { $0.value == "{{Date.now()}}" }?.name)
        try requirePreflight(Set(query.map(\.name)).count == query.count && query.count == 5,
                             "目录参数必须与固定包中预审的五项完全一致")
        let fixed = Dictionary(uniqueKeysWithValues: query.filter { $0.name != offset && $0.name != timestamp }.map { ($0.name, $0.value ?? "") })
        let origin = try XCTUnwrap(URL(string: source.url).flatMap(SourceRequestHeaderScope.origin))
        try requirePreflight(parts.url.flatMap(SourceRequestHeaderScope.origin) == origin
                             && !fixed.values.contains(where: { $0.contains("{{") }),
                             "只准入同源且除两项纯表达式外完全固定的目录目标")
        let path = parts.percentEncodedPath
        let earliest = Int64(Date().timeIntervalSince1970 * 1_000)
        return { url in
            guard SourceRequestHeaderScope.origin(url) == origin,
                  let target = URLComponents(url: url, resolvingAgainstBaseURL: false),
                  target.percentEncodedPath == path, target.fragment == nil,
                  let values = target.queryItems, values.count == fixed.count + 2,
                  Set(values.map(\.name)).count == values.count else { return false }
            let actual = Dictionary(uniqueKeysWithValues: values.map { ($0.name, $0.value ?? "") })
            guard actual[offset] == "0", let time = actual[timestamp].flatMap(Int64.init),
                  (earliest...(earliest + 25_000)).contains(time) else { return false }
            return fixed.allSatisfy { actual[$0.key] == $0.value }
        }
    }

    @MainActor
    private func reviewedMediaURL(_ raw: String, source: RSSSource, hostHash: String) async throws -> URL {
        try await validateFlowURL(raw, source: source, sameOrigin: false)
        let url = try XCTUnwrap(URL(string: raw))
        let hash = Self.hostDigest(url)
        if hash != hostHash || url.query != nil || url.fragment != nil {
            let kind = hostHash.hasPrefix("2dcc4a77") ? "article" : "audio"
            print("S8_AUDIO_TARGET_REJECT kind=\(kind) hostMatches=\(hash == hostHash) hasQuery=\(url.query != nil) hasFragment=\(url.fragment != nil)")
        }
        try requirePreflight(hash == hostHash && url.query == nil && url.fragment == nil,
                             "音频或正文目标不符合预审HTTPS主机和无参数合同")
        return url
    }

    @MainActor
    func testPreScreenedPublicImageSourceRulesParseSyntheticMatchingDOM() async throws {
        let source = try await Task.detached(priority: .utility) { try Self.reviewedImageSource() }.value
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

    @MainActor
    func testReviewedB122SearchResponseShapeAudit() async throws {
        await MainActor.run { _ = GlobalSettings.shared }
        let source = try await Task.detached(priority: .utility) { try Self.reviewedImageSource() }.value
        let checkWord = source.ruleSearch.checkKeyWord
        try requirePreflight(!checkWord.isEmpty && checkWord.count <= 32,
                             "B122源内检查词不符合预审范围")
        let queries = ["三体", checkWord]
        var urls: [URL] = []
        for query in queries {
            let rendered = await source.renderSearchURL(query: query, page: 1)
            try requirePreflight(rendered.method.uppercased() == "GET" && rendered.body == nil,
                                 "只审计B122两个只读首页搜索")
            let url = try XCTUnwrap(URL(string: RuleEngine.resolveURL(rendered.url, base: source.cleanedBookSourceURL)))
            let origin = try XCTUnwrap(URL(string: source.cleanedBookSourceURL))
            try requirePreflight(url.scheme == "https" && url.host == origin.host && url.port == origin.port
                                 && url.user == nil && url.password == nil && url.fragment == nil,
                                 "B122搜索地址超出预审同源HTTPS范围")
            try requirePreflight(CookieStore.shared.get(url: url.absoluteString).isEmpty
                                 && (HTTPCookieStorage.shared.cookies(for: url) ?? []).isEmpty,
                                 "B122目标已有Cookie，停止无凭据审计")
            let mirrored = await WebViewCookieMirror.shared.cookies(for: url.host ?? "")
            try requirePreflight(mirrored.isEmpty, "B122目标已有网页Cookie，停止审计")
            urls.append(url)
        }
        let (_, session, meter) = try makeFetcher(urls: urls.map(\.absoluteString), maximumRequests: 2)
        defer { session.invalidateAndCancel(); meter.boundary?.close() }
        let fetcher = WebFetcher(session: session)
        do {
            try await SourceDiagnosticContext.$restrictedTask.withValue(true) {
                for (index, url) in urls.enumerated() {
                    let page = try await fetcher.fetchPage(url: url, method: "GET", body: nil, headers: [:],
                                                          baseURL: source.cleanedBookSourceURL)
                    try requirePreflight(page.statusCode == 200 && page.data.count <= 1_048_576,
                                         "B122未返回范围内的200响应，停止审计")
                    let html = try await SourceScriptThread.run {
                        try XCTUnwrap(HTMLResponseDecoder.decode(data: page.data, response: page.response))
                    }
                    let shape = try await SourceScriptThread.run {
                        let document = try SwiftSoup.parse(html)
                        let nodes = try document.select(".content article, article.content").array()
                        let valid = try nodes.filter {
                            try !$0.select("h2").text().trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                && !($0.select("h2 a[href]").first()?.attr("href") ?? "").isEmpty
                        }.count
                        let text = try document.body()?.text().lowercased() ?? ""
                        let noResults = ["未找到", "没有找到", "沒找到", "nothing found", "no results"].contains { text.contains($0) }
                        let challenge = ["cf-chl-", "challenge-platform", "g-recaptcha", "h-captcha"].contains { html.lowercased().contains($0) }
                        return (nodes.count, valid, noResults, challenge)
                    }
                    let books = try await BookSourceParsingPipeline().parseSearchResults(html: html,
                        baseURL: page.response.url?.absoluteString ?? url.absoluteString, source: source)
                    let kind = index == 0 ? "original-query" : "source-check-word"
                    print("S8_B122_SHAPE scope=\(kind) status=200 bytes=\(page.data.count) ruleNodes=\(shape.0) validNodes=\(shape.1) parsed=\(books.count) noResultText=\(shape.2) challengeMarker=\(shape.3)")
                    try requirePreflight(shape.1 == 0 || !books.isEmpty,
                                         "B122响应含可匹配节点而引擎仍为空，必须继续定位，不能算通过")
                }
            }
            let audit = meter.snapshot()
            XCTAssertEqual(audit.transactions, 2)
            XCTAssertEqual(audit.statusCodes, [200, 200])
            XCTAssertEqual(audit.credentialHeadersSent, 0)
            XCTAssertEqual(meter.boundary?.counts.rejected, 0)
        } catch {
            if error is PreflightFailure { throw error }
            let kind = (error as NSError).domain == NSURLErrorDomain ? "url" : "other"
            print("S8_B122_SHAPE_FAILURE domain=\(kind) requests=\(meter.snapshot().transactions)")
            XCTFail("B122响应审计失败；不输出URL、查询词、正文或任意错误文本")
            throw PreflightFailure.rejected
        }
    }

    private static func reviewedImageSource() throws -> BookSource {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("docs/Booksource.json"), options: .mappedIfSafe)
        try requirePreflight(SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                             == "3794d5f877d3369dc422145a1187f3dd5fe1f128486991b7fc95dc08de6ad9fc",
                             "B122规则检查仅适用于固定预审包")
        let rows = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        try requirePreflight(rows.count == 253, "固定书源包项数变化，停止解析")
        let candidate = try XCTUnwrap(rows.dropFirst(121).first)
        let one = try JSONSerialization.data(withJSONObject: [candidate], options: [.sortedKeys])
        var source = try XCTUnwrap(JSONDecoder().decode([BookSource].self, from: one).first)
        source.bookSourceName = "S8 image source #122"
        let serialized = String(decoding: one, as: UTF8.self).lowercased()
        try requirePreflight(source.bookSourceType == 2 && !source.searchUrl.isEmpty,
                             "B122检查只允许预审的图片书源搜索规则")
        try requirePreflight(source.header.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                             && source.loginUrl.isEmpty && source.loginUi.isEmpty && source.loginCheckJs.isEmpty
                             && source.jsLib.isEmpty && source.coverDecodeJs.isEmpty,
                             "图片源含认证或可执行脚本，不进入B122检查")
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
        await MainActor.run { _ = GlobalSettings.shared } // 隔离宿主不启动App；原生书源搜索仍需合法的设置快照。
        let (original, requestURL) = try await bookSource(at: 2)
        var source = original
        source.bookSourceName = "S8 text source #2"
        source.lastUpdateTime = Int64(Date().timeIntervalSince1970 * 1_000) // 仅隔离测试缓存key，不改请求和规则。
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
        let boundary = try S8RequestBoundary(urls: [url], maximumRequests: 1)
        boundary.configure(configuration)
        let meter = S8RequestMeter(boundary: boundary)
        let session = URLSession(configuration: configuration, delegate: meter, delegateQueue: nil)
        defer { session.invalidateAndCancel(); boundary.close() }
        let fetcher = BookSourceFetcher(webFetcher: WebFetcher(session: session))
        let query = "三体"
        defer { SearchResultCache.shared.clear(query: query, source: source) }
        let started = ContinuousClock.now
        let outcome: BookSourceSearchOutcome
        do { outcome = try await fetcher.searchOutcome(query: query, in: source, failureMode: .propagateTransportError) }
        catch {
            let kind = (error as NSError).domain == "S8RequestBoundary" ? "boundary" : "other"
            print("S8_BOOK_REQUEST_FAILURE ordinal=2 domain=\(kind) code=\((error as NSError).code)")
            XCTFail("书源搜索请求失败，保留边界诊断，不输出URL或错误正文")
            throw PreflightFailure.rejected
        }
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
        try requirePreflight(rows.count == 307 && [14, 128, 141, 146, 181, 217, 265].contains(ordinal),
                             "未预审的RSS条目，拒绝联网")
        let raw = rows[ordinal - 1]
        let candidateData = try JSONSerialization.data(withJSONObject: [raw], options: [.sortedKeys])
        let loaded = try await RSSImportService.load(.data(candidateData))
        XCTAssertEqual(loaded.requests, 0, "读取配置本身不请求网络或执行规则")
        let source = try XCTUnwrap(loaded.candidates.first?.source)
        XCTAssertEqual(loaded.candidates.count, 1)
        XCTAssertTrue(loaded.candidates.first?.issue == nil)
        try requirePreflight([source.header, source.loginUrl, source.loginUi, source.loginCheckJs,
                              source.jsLib, source.injectJs, source.preloadJs, source.variable, source.startJs, source.coverDecodeJs]
            .allSatisfy { $0?.isEmpty != false }, "源含认证或脚本配置，拒绝联网")
        let parts = try XCTUnwrap(URLComponents(string: source.url))
        XCTAssertEqual(parts.scheme?.lowercased(), "https")
        XCTAssertNil(parts.user)
        XCTAssertNil(parts.password)
        if ordinal != 141 { XCTAssertNil(parts.query) }
        else {
            try requirePreflight(parts.queryItems?.count == 5 && source.rulePubDate?.contains("@put:{audio:$.audioUrl}") == true,
                                 "只允许固定包R141已预审的公开目录参数与条目音频变量规则")
        }
        XCTAssertNil(parts.fragment)

        // R141仅额外准入对当前条目audio变量的纯读取，不放行任意源JS或网页脚本。
        let serialized = String(decoding: candidateData, as: UTF8.self)
        var lowercased = serialized.lowercased()
        if ordinal == 141 {
            try requirePreflight((source.ruleContent ?? "").components(separatedBy: "java.get('audio')").count == 2,
                                 "R141正文必须只读取一次列表条目的音频变量")
            lowercased = lowercased.replacingOccurrences(of: "java.get('audio')", with: "")
        }
        for marker in ["@js:", "<js>", "javascript:", "java.", "window.location", "document.cookie"] {
            try requirePreflight(!lowercased.contains(marker), "预审源包含脚本特征，停止网络验收")
        }
        for method in ["post", "put", "delete", "patch"] {
            try requirePreflight(!lowercased.contains("\"method\":\"\(method)\""), "预审源包含非只读方法，停止网络验收")
        }
        return source
    }

    @MainActor
    private func makeFetcher(urls: [String], maximumRequests: Int = 1, expectedOrigin: String? = nil,
                             approvedURLHashes: Set<String> = [], allowsHead: Bool = false,
                             approvedDynamicURL: (@Sendable (URL) -> Bool)? = nil) throws -> (RSSFetcher, URLSession, S8RequestMeter) {
        let boundary = try S8RequestBoundary(urls: urls.map { try XCTUnwrap(URL(string: $0)) }, maximumRequests: maximumRequests,
                                            approvedURLHashes: approvedURLHashes, allowsHead: allowsHead, approvedDynamicURL: approvedDynamicURL)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 25
        configuration.httpMaximumConnectionsPerHost = 1
        boundary.configure(configuration)
        let meter = S8RequestMeter(expectedOrigin: expectedOrigin, boundary: boundary)
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
