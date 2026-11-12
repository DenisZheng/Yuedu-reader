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

    func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        lock.lock()
        transactionCount += metrics.transactionMetrics.count
        statusCodes += metrics.transactionMetrics.compactMap { ($0.response as? HTTPURLResponse)?.statusCode }
        for transaction in metrics.transactionMetrics {
            requestMethods.append((transaction.request.httpMethod ?? "GET").uppercased())
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

    func snapshot() -> (transactions: Int, statusCodes: [Int], requestMethods: [String], credentialHeadersSent: Int, redirectsBlocked: Int) {
        lock.lock()
        defer { lock.unlock() }
        return (transactionCount, statusCodes, requestMethods, credentialHeadersSent, redirectsBlocked)
    }
}

/// Only reads two individually pre-screened entries; never executes the complete pack.
/// Each test makes one unauthenticated GET, disables cookies/credentials/cache and blocks redirects.
final class S8RepresentativeSourceTests: XCTestCase {
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
        XCTAssertFalse(source.singleUrl)
        XCTAssertNotNil(source.ruleArticles)
        XCTAssertNotNil(source.ruleTitle)
        XCTAssertNotNil(source.ruleLink)
        XCTAssertNotNil(source.ruleNextPage)
        let (fetcher, session, meter) = makeFetcher()
        defer { session.invalidateAndCancel() }
        let started = ContinuousClock.now
        await fetcher.fetchItems(from: source, page: 1, resolveEntry: false)
        let elapsed = Self.milliseconds(since: started)
        let request = meter.snapshot()
        XCTAssertTrue(fetcher.error == nil, "公开规则列表请求应成功；错误文本与来源URL不进入测试输出")
        XCTAssertGreaterThan(fetcher.items.count, 0)
        XCTAssertNotNil(fetcher.listPage)
        XCTAssertEqual(request.transactions, 1, "只请求第一页；不自动跟随下一页")
        XCTAssertEqual(request.statusCodes, [200])
        XCTAssertEqual(request.requestMethods, ["GET"])
        XCTAssertEqual(request.credentialHeadersSent, 0)
        XCTAssertEqual(request.redirectsBlocked, 0)
        print("S8_REAL_SOURCE ordinal=14 kind=public-rule-list requests=\(request.transactions) status=\(request.statusCodes.first ?? 0) parsedItems=\(fetcher.items.count) hasNextPage=\(fetcher.listPage?.nextURL != nil) elapsedMs=\(elapsed) cookies=disabled credentials=none redirects=blocked")
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
        XCTAssertTrue(CookieStore.shared.get(url: url.absoluteString).isEmpty,
                      "如果此主机已有Legado持久Cookie，拒绝真实请求")
        XCTAssertTrue((HTTPCookieStorage.shared.cookies(for: url) ?? []).isEmpty,
                      "如果此主机已有URLSession Cookie，拒绝真实请求")
        let mirroredCookies = await WebViewCookieMirror.shared.cookies(for: host)
        XCTAssertTrue(mirroredCookies.isEmpty,
                      "如果此主机已有WebKit Cookie，拒绝真实请求")

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
        XCTAssertEqual(SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
                       "3794d5f877d3369dc422145a1187f3dd5fe1f128486991b7fc95dc08de6ad9fc",
                       "真实源抽查仅适用于静态审计过的固定包")
        let rows = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        XCTAssertEqual(rows.count, 253)
        XCTAssertGreaterThanOrEqual(ordinal, 1)
        XCTAssertLessThanOrEqual(ordinal, rows.count)
        let one = try JSONSerialization.data(withJSONObject: [rows[ordinal - 1]], options: [.sortedKeys])
        let decoded = try XCTUnwrap(JSONDecoder().decode([BookSource].self, from: one).first)
        let serialized = String(decoding: one, as: UTF8.self).lowercased()
        for marker in ["@js:", "<js>", "javascript:", "window.location", "document.cookie", "java.connect", "downloadfile"] {
            XCTAssertFalse(serialized.contains(marker), "预审来源含潜在脚本或副作用特征，停止联网")
        }
        for method in ["post", "put", "patch", "delete"] {
            XCTAssertFalse(serialized.contains("\"method\":\"\(method)\""), "预审来源含非只读方法，停止联网")
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
        XCTAssertEqual(SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
                       "0e30301c85fb511961be7542212ee63b8d4173a9b6c33bb5a4f88eb6d3795f45",
                       "实源抽查仅适用已经静态审计过的固定包")
        let rows = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        XCTAssertEqual(rows.count, 307)
        XCTAssertGreaterThanOrEqual(ordinal, 1)
        XCTAssertLessThanOrEqual(ordinal, rows.count)
        let raw = rows[ordinal - 1]
        let candidateData = try JSONSerialization.data(withJSONObject: [raw], options: [.sortedKeys])
        let loaded = try await RSSImportService.load(.data(candidateData))
        XCTAssertEqual(loaded.requests, 0, "读取配置本身不请求网络或执行规则")
        let source = try XCTUnwrap(loaded.candidates.first?.source)
        XCTAssertEqual(loaded.candidates.count, 1)
        XCTAssertTrue(loaded.candidates.first?.issue == nil)
        XCTAssertNil(source.header)
        XCTAssertNil(source.loginUrl)
        XCTAssertNil(source.loginUi)
        XCTAssertNil(source.loginCheckJs)
        XCTAssertNil(source.jsLib)
        XCTAssertNil(source.injectJs)
        XCTAssertNil(source.preloadJs)
        XCTAssertNil(source.variable)
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
            XCTAssertFalse(lowercased.contains(marker), "预审源包含脚本特征，停止网络验收")
        }
        for method in ["post", "put", "delete", "patch"] {
            XCTAssertFalse(lowercased.contains("\"method\":\"\(method)\""), "预审源包含非只读方法，停止网络验收")
        }
        return source
    }

    @MainActor
    private func makeFetcher() -> (RSSFetcher, URLSession, S8RequestMeter) {
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
        return (RSSFetcher(session: session), session, meter)
    }

    private static func milliseconds(since start: ContinuousClock.Instant) -> Int {
        let duration = start.duration(to: .now).components
        return Int(duration.seconds * 1_000 + duration.attoseconds / 1_000_000_000_000_000)
    }
}
