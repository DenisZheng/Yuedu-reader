import Foundation
import Testing
@testable import yuedu_app

@Suite("原生只读段评合同", .serialized)
@MainActor
struct NativeReviewTests {
    @Test("ReviewRule承载原生摘要及详情协议，不仅保留未知JSON")
    func executableReviewConfiguration() throws {
        let raw = #"{"enabled":true,"reviewSummaryUrl":"https://review.invalid/summary","summaryListRule":"$.items","summaryParagraphIndexRule":"$.index","summaryCountRule":"$.count","reviewDetailUrl":"https://review.invalid/detail","detailListRule":"$.items"}"#
        let rule = try JSONDecoder().decode(ReviewRule.self, from: Data(raw.utf8))
        let object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(rule)) as? [String: Any])
        #expect(object["enabled"] as? Bool == true)
        #expect(object["summaryListRule"] as? String == "$.items")
        #expect(object["detailListRule"] as? String == "$.items")
    }

    static func source() -> BookSource {
        var source = BookSource(bookSourceUrl: "https://native-review-" + UUID().uuidString.lowercased() + ".invalid", bookSourceName: "自建原生段评")
        source.ruleReview.enabled = true
        source.ruleReview.reviewSummaryUrl = "/summary"
        source.ruleReview.summaryListRule = "$.items[*]"
        source.ruleReview.summaryParagraphIndexRule = "$.index"
        source.ruleReview.summaryCountRule = "$.count"
        source.ruleReview.summaryParagraphDataRule = "$.key"
        source.ruleReview.reviewDetailUrl = "/detail?p={{page}}&para={{paraIndex}}"
        source.ruleReview.reviewDetailNextPageUrl = "$.next"
        source.ruleReview.detailListRule = "$.items[*]"
        source.ruleReview.detailIdRule = "$.id"
        source.ruleReview.detailNameRule = "$.name"
        source.ruleReview.detailContentRule = "$.content"
        source.ruleReview.detailBadgeRule = "$.badge"
        source.ruleReview.reviewQuoteUrl = "/replies?review={{reviewId}}&page={{page}}"
        source.ruleReview.replyListRule = "$.replies[*]"
        source.ruleReview.replyIdRule = "$.id"
        source.ruleReview.replyNameRule = "$.name"
        source.ruleReview.replyContentRule = "$.content"
        return source
    }
    static func client(_ source: BookSource, session: BookSourceSession? = nil) -> NativeReviewClient {
        var book = ReadingBook(title: "段评固定书", contentFilename: "")
        book.isOnline = true; book.bookSourceId = source.id
        book.bookInfoURL = source.bookSourceUrl + "/book"
        let ref = OnlineChapterRef(index: 3, title: "第三章", url: source.bookSourceUrl + "/chapter/3")
        return NativeReviewClient(source: source, book: book, chapter: ref, session: session)
    }

    @Test("声明式摘要、详情协议内容、独立回复及参数读取真实有限响应")
    func declarativeReviewFlow() async throws {
        let source = Self.source(), host = try #require(URL(string: source.bookSourceUrl)?.host)
        RSSPageFixtureProtocol.serve(host: host, sequences: [
            "/summary": [.init(body: Data(#"{"items":[{"index":-1,"count":2,"key":"title"},{"index":1,"count":3,"key":"first"},{"index":0,"count":100}]}"#.utf8))],
            "/detail": [.init(body: Data(#"{"items":[{"id":"r1","name":"作者","content":"普通段评","badge":"作者|会员"}],"next":"/second"}"#.utf8))],
            "/replies": [.init(body: Data(#"{"replies":[{"id":"q1","name":"回复者","content":"回复内容"}]}"#.utf8))]
        ])
        defer { RSSPageFixtureProtocol.remove(host: host) }
        let session = BookSourceSession(source: source, requestSession: RSSPageFixtureProtocol.makeSession())
        let client = Self.client(source, session: session)
        let summary = try await client.summary()
        #expect(summary.paragraphs.map(\.index) == [-1,1])
        let paragraph = try #require(summary.paragraphs.last)
        let detail = try await client.detail(paragraph: paragraph, page: 1)
        #expect(detail.items.first?.sourceID == "r1" && detail.items.first?.text == "普通段评")
        #expect(detail.items.first?.badges == ["作者", "会员"])
        #expect(detail.nextPageURL == source.bookSourceUrl + "/second")
        let replies = try await client.detail(paragraph: paragraph, page: 1, reviewID: "r1")
        #expect(replies.items.first?.text == "回复内容")
        let requests = RSSPageFixtureProtocol.requests(host: host)
        #expect(requests.count == 3)
        #expect(requests[1].url?.query?.contains("para=1") == true)
        #expect(requests[2].url?.query?.contains("review=r1") == true)
    }

    @Test("主脚本摘要、内容对象、内嵌与独立回复按可选函数合同分流")
    func mainJsReviewFlow() async throws {
        var source = Self.source()
        source.mainJs = """
        function getReviewSummary(chapter,book){return [{paraIndex:-1,count:2,paraData:'title'},{paraIndex:1,count:4,paraData:'data'}];}
        function getReviewDetail(chapter,book,paraIndex,paraData,page){return {items:[{id:'r1',name:'作者',content:{text:'内容'+paraIndex+paraData,replyCount:2,img:'/image'},replies:[{id:'q1',content:'内嵌回复',replies:[{id:'q2',content:'内层回复'}]}]}],nextPageUrl:'/next'};}
        function getReviewReplies(chapter,book,paraIndex,paraData,reviewId,page){return {items:[{id:'q1',content:'独立回复'+reviewId,replies:[{id:'q2',content:'嵌套回复'}]}]};}
        """
        let client = Self.client(source)
        let summary = try await client.summary(), paragraph = try #require(summary.paragraphs.last)
        let detail = try await client.detail(paragraph: paragraph, page: 1)
        #expect(detail.items.first?.text == "内容1data")
        #expect(detail.items.first?.image == source.bookSourceUrl + "/image")
        #expect(detail.items.first?.replies.map(\.text) == ["内嵌回复", "内层回复"])
        #expect(detail.hasSeparateReplies)
        let replies = try await client.detail(paragraph: paragraph, page: 1, reviewID: "r1")
        #expect(replies.items.map(\.text) == ["独立回复r1", "嵌套回复"])
    }

    @Test("分页失败保留原目标，重试才推进；重复下一页不会无限加载")
    func pagerRetryAndLoop() async throws {
        let source = Self.source(), host = try #require(URL(string: source.bookSourceUrl)?.host)
        RSSPageFixtureProtocol.serve(host: host, sequences: [
            "/detail": [.init(body: Data(#"{"items":[{"id":"r1","content":"第一页"}],"next":"/second"}"#.utf8))],
            "/second": [.init(body: Data("失败".utf8), status: 503), .init(body: Data(#"{"items":[{"id":"r2","content":"第二页"}],"next":"/second"}"#.utf8))]
        ])
        defer { RSSPageFixtureProtocol.remove(host: host) }
        let client = Self.client(source, session: BookSourceSession(source: source, requestSession: RSSPageFixtureProtocol.makeSession()))
        let pager = NativeReviewPager(client: client, paragraph: .init(index: 1, data: "key", count: 3))
        await pager.loadNext()
        #expect(pager.page == 2 && pager.items.count == 1)
        await pager.loadNext()
        #expect(pager.page == 2 && pager.failure == .response)
        await pager.loadNext()
        #expect(pager.page == 2 && pager.failure == .loop)
        #expect(RSSPageFixtureProtocol.requests(host: host).map { $0.url?.path } == ["/detail", "/second", "/second"])
    }

    @Test("相对分页游标按详情响应定位，页号按实际下一页替换")
    func followsRelativePageTemplate() async throws {
        var source = Self.source(); source.ruleReview.reviewDetailUrl = "/reviews/detail"
        let host = try #require(URL(string: source.bookSourceUrl)?.host)
        RSSPageFixtureProtocol.serve(host: host, sequences: [
            "/reviews/detail": [
                .init(body: Data(#"{"items":[{"id":"r1","content":"第一页"}],"next":"?page={{page}}"}"#.utf8)),
                .init(body: Data(#"{"items":[{"id":"r2","content":"第二页"}]}"#.utf8))
            ]
        ])
        defer { RSSPageFixtureProtocol.remove(host: host) }
        let client = Self.client(source, session: BookSourceSession(source: source, requestSession: RSSPageFixtureProtocol.makeSession()))
        let pager = NativeReviewPager(client: client, paragraph: .init(index: 1, data: "key", count: 2))
        await pager.loadNext()
        await pager.loadNext()
        #expect(pager.items.map(\.text) == ["第一页", "第二页"] && !pager.hasMore && pager.failure == nil)
        #expect(RSSPageFixtureProtocol.requests(host: host).last?.url?.query == "page=2")
    }

    @Test("认证头不能因段评请求跨域泄露")
    func authenticationScope() async throws {
        var source = Self.source()
        let other = "https://review-other-" + UUID().uuidString.lowercased() + ".invalid"
        source.header = #"{"Authorization":"fixture-not-secret","X-Private":"fixture-not-secret"}"#
        source.ruleReview.reviewSummaryUrl = other + "/summary"
        let host = try #require(URL(string: other)?.host)
        RSSPageFixtureProtocol.serve(host: host, sequences: ["/summary":[.init(body:Data(#"{"items":[]}"#.utf8))]])
        defer { RSSPageFixtureProtocol.remove(host: host) }
        let client = Self.client(source, session: BookSourceSession(source: source, requestSession: RSSPageFixtureProtocol.makeSession()))
        #expect(try await client.summary().paragraphs.isEmpty)
        let request = try #require(RSSPageFixtureProtocol.requests(host: host).first)
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(request.value(forHTTPHeaderField: "X-Private") == nil)
    }

    @Test("读取超限与规则变更各自停止当前段评请求")
    func byteLimitAndRevision() async throws {
        var source = Self.source()
        let host = try #require(URL(string: source.bookSourceUrl)?.host)
        RSSPageFixtureProtocol.serve(host: host, contentType: "application/json",
                                     body: Data(repeating: 0x20, count: 1_048_577))
        defer { RSSPageFixtureProtocol.remove(host: host) }
        let session = BookSourceSession(source: source, requestSession: RSSPageFixtureProtocol.makeSession())
        let client = Self.client(source, session: session)
        await #expect(throws: NativeReviewFailure.budget) { try await client.summary() }
        source.ruleReview.enabled = false
        BookSourceSession.invalidateMainJsSessions(previous: [source.id: 0], current: [source], positions: [source.id: 0])
        await #expect(throws: NativeReviewFailure.unavailable) { try await client.summary() }
        #expect(RSSPageFixtureProtocol.requests(host: host).count == 1)
    }

    @Test("声明式 HTML 保留标题及缺省键，详情规范化徽章、相对附件和内嵌回复")
    func declarativeHTMLAndInlineReplies() async throws {
        var source = Self.source()
        source.ruleReview.summaryListRule = "@CSS:.paragraph"
        source.ruleReview.summaryParagraphIndexRule = "@CSS:span.idx@text"
        source.ruleReview.summaryParagraphDataRule = "@CSS:span.missing@text"
        source.ruleReview.summaryCountRule = "@CSS:span.count@text"
        source.ruleReview.reviewQuoteUrl = ""
        let host = try #require(URL(string: source.bookSourceUrl)?.host)
        RSSPageFixtureProtocol.serve(host: host, sequences: [
            "/summary": [.init(body: Data(#"<div class="paragraph"><span class="idx">-1</span><span class="count">2</span></div><div class="paragraph"><span class="idx">raw-key</span><span class="count">3</span></div>"#.utf8))],
            "/detail": [.init(body: Data(#"{"items":[{"id":"r","badge":["作者","VIP"],"content":{"img":"pictures/a.png","replyCount":1},"replies":[{"id":"q","content":{"text":"内嵌回复","replyToName":"作者"}}]}]}"#.utf8))]
        ])
        defer { RSSPageFixtureProtocol.remove(host: host) }
        let client = Self.client(source, session: BookSourceSession(source: source, requestSession: RSSPageFixtureProtocol.makeSession()))
        let summary = try await client.summary()
        #expect(summary.paragraphs.map(\.index) == [-1, 2])
        let paragraph = try #require(summary.paragraphs.last)
        #expect(paragraph.data == "raw-key")
        let detail = try await client.detail(paragraph: paragraph, page: 1)
        let row = try #require(detail.items.first)
        #expect(row.text.isEmpty && row.image == source.bookSourceUrl + "/pictures/a.png")
        #expect(row.badges == ["作者", "VIP"])
        #expect(row.replies.first?.text == "内嵌回复" && row.replies.first?.replyToName == "作者")
    }

    @Test("回复端点重复返回同一页时结束，不因无下一页字段而继续递增")
    func repeatedRepliesExhaustPagination() async throws {
        var source = Self.source()
        source.mainJs = "function getReviewReplies(){return {items:[{id:'r',content:'一条回复'}]};}"
        let pager = NativeReviewPager(client: Self.client(source), paragraph: .init(index: 1, data: "key", count: 1), reviewID: "parent")
        await pager.loadNext()
        #expect(pager.hasMore)
        await pager.loadNext()
        #expect(!pager.hasMore && pager.failure == nil && pager.items.map(\.text) == ["一条回复"])
    }

    @Test("条数和脚本错误不冒充合法空摘要")
    func budgetsAndScriptErrors() async throws {
        for script in ["function getReviewSummary(){throw new Error('fixture');}",
                       "function getReviewSummary(){return Array.from({length:1001},function(_,i){return {paraIndex:i+1,count:1};});}"] {
            var source = Self.source(); source.mainJs = script
            await #expect(throws: (any Error).self) { try await Self.client(source).summary() }
        }
        let source = Self.source(), session = BookSourceSession(source: Self.source())
        session.invalidate()
        await #expect(throws: (any Error).self) { try await Self.client(source, session: session).summary() }
    }

    @Test("坏CSS统计规则不能被显示为没有段评")
    func invalidCSSIsFailure() async throws {
        var source = Self.source(); source.ruleReview.summaryListRule = "@CSS:.broken["
        let host = try #require(URL(string: source.bookSourceUrl)?.host)
        RSSPageFixtureProtocol.serve(host: host, contentType: "text/html", body: Data("<p>固定页面</p>".utf8))
        defer { RSSPageFixtureProtocol.remove(host: host) }
        let client = Self.client(source, session: BookSourceSession(source: source, requestSession: RSSPageFixtureProtocol.makeSession()))
        await #expect(throws: (any Error).self) { try await client.summary() }
    }

    @Test("取消和配置失效以后被释放的旧响应不能写回分页状态")
    func lateResultInvalidated() async throws {
        for cancel in [true, false] {
            let source = Self.source(), host = try #require(URL(string: source.bookSourceUrl)?.host)
            let stream = AsyncStream<URLRequest>.makeStream()
            RSSPageFixtureProtocol.serve(host: host, sequences: ["/detail":[.init(body: Data(#"{"items":[{"id":"late","content":"过期"}]}"#.utf8), held: true)]], events: stream.continuation)
            let session = BookSourceSession(source: source, requestSession: RSSPageFixtureProtocol.makeSession())
            let pager = NativeReviewPager(client: Self.client(source, session: session), paragraph: .init(index: 1, data: "key", count: 1))
            let task = Task { await pager.loadNext() }
            var iterator = stream.stream.makeAsyncIterator()
            _ = await iterator.next()
            if cancel { pager.cancel(); task.cancel() } else { session.invalidate() }
            RSSPageFixtureProtocol.release(host: host)
            await task.value
            #expect(pager.items.isEmpty && pager.page == 1)
            RSSPageFixtureProtocol.remove(host: host)
        }
    }

    @Test("缺可选函数、合法空和格式错误不可混为一种成功")
    func unavailableEmptyAndMalformed() async throws {
        for body in ["", "function getReviewSummary(){return [];}", "function getReviewSummary(){return {items:[]};}"] {
            var source = Self.source(); source.mainJs = body.isEmpty ? "function getContent(){return '正文';}" : body
            let client = Self.client(source)
            if body.contains("return []") { #expect(try await client.summary().paragraphs.isEmpty) }
            else { await #expect(throws: (any Error).self) { try await client.summary() } }
        }
        #expect(NativeReviewValues.integer(true) == nil)
        let item = try #require(try NativeReviewValues.item(["id":"", "content":"正文"], base: "https://native-review.invalid"))
        #expect(!item.id.isEmpty)
    }
}
