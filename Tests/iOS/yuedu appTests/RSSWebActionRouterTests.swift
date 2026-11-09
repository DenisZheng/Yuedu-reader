import Foundation
import Testing
@testable import yuedu_app

@Suite("RSS native action routing", .serialized)
@MainActor struct RSSWebActionRouterTests {
    @Test("跨家族只接收URL字面量与origin元数据，不在书源宿主执行RSS提供的URL脚本")
    func bookOptionsDoNotBecomeCode() async throws {
        let source = BookSource(bookSourceUrl: "https://books-fixture.invalid", bookSourceName: "Synthetic books")
        let good = try await RSSWebActionRouter.bookRequest("https://books-fixture.invalid/book?part=1#page,{origin:'https://books-fixture.invalid'}",
                                                          sources: [source], base: nil)
        #expect(good.source.id == source.id)
        #expect(good.url == "https://books-fixture.invalid/book?part=1#page")
        let denied = [
            "https://books-fixture.invalid/book,{js:'java.put(\"private\",\"x\")',origin:'https://books-fixture.invalid'}",
            "https://other-fixture.invalid/book,{origin:'https://books-fixture.invalid'}",
            "@js:source.getLoginInfo()"
        ]
        for url in denied {
            do { _ = try await RSSWebActionRouter.bookRequest(url, sources: [source], base: nil); Issue.record("跨源代码/认证边界未拒绝") }
            catch { #expect(error is RSSWebFailure) }
        }
    }
    @Test("网页分类限于当前origin并按字面量处理；配置脚本的规则URL不被静默删options")
    func categoryAuthority() async throws {
        let base = URL(string: "https://rss-fixture.invalid/page")!
        let entries = try await RSSWebActionRouter.sortEntries(#"{"Test":"/list?key={{1+2}},{'js':'private'}"}"#,
                                                               title: nil, base: base, trusted: false)
        #expect(try LegadoSortURLParser.actionEntries(from: #"{"Z":"/z","A":"/a"}"#, title: nil).map(\.name) == ["Z", "A"])
        let entry = try #require(entries.first)
        #expect(!AnalyzeUrl.hasOptions(entry.url))
        #expect(!entry.url.contains("{{"))
        let configured = "https://other-fixture.invalid/list,{'method':'POST','body':'value'}"
        #expect(try await RSSWebActionRouter.sortEntries(configured, title: nil, base: base, trusted: true).first?.url == configured)
        do {
            _ = try await RSSWebActionRouter.sortEntries("https://other-fixture.invalid/list", title: nil, base: base, trusted: false)
            Issue.record("网页把来源认证授权给了外站分类")
        } catch { #expect(error is RSSWebFailure) }
    }
    @Test("外站RSS页面意图先确认外部链接，不获得当前源的页面桥或认证")
    func externalPageDoesNotGetSourceAuthority() async throws {
        try await fixture { owner, source in
            let model = RSSWebActionRouter()
            let request = request(.rss(url: "https://other-fixture.invalid/page", title: nil, origin: nil), source: source, owner: owner)
            try model.receive(request, source: source, owner: owner)
            try await ready(model)
            #expect(model.destination == nil)
            let confirmation = try #require(model.confirmation)
            guard case .external(let url) = confirmation.kind else { Issue.record("外站不应获得源页面权限"); return }
            #expect(url.host == "other-fixture.invalid")
        }
    }
    @Test("拦截脚本的有限java只作用于该次求值，不污染后续共享解析器")
    func actionJavaDoesNotReplaceParserJava() async throws {
        var source = RSSSource(name: "Java restore", url: "https://restore-" + UUID().uuidString + ".invalid")
        source.shouldOverrideUrlLoading = "java.put('fixture','value');true"
        _ = try await RSSWebNavigation.intercept(URL(string: source.url + "/blocked")!, source: source, context: nil, owner: nil)
        let runtime = try await RSSRuntime.make(source: source)
        let result = try await runtime.run { host in
            try await host.run { bridge in
                try bridge.withRuleContext(content: "", baseURL: runtime.source.sourceKey, scope: RuleData(), stage: "rss.fixture") {
                    $0.getString(ruleStr: "@js:typeof java.ajax")
                }
            }
        }
        #expect(result == "function")
    }

    @Test("确认前凭据变化不执行外部动作；取消和旧owner拒收")
    func confirmationRevalidates() async throws {
        try await fixture { owner, source in
            let model = RSSWebActionRouter()
            let input = request(.external(URL(string: "https://external-fixture.invalid")!), source: source, owner: owner)
            try model.receive(input, source: source, owner: owner)
            try await ready(model)
            #expect(model.confirmation != nil)
            let key = RSSRuntime.authenticationKey(for: source)
            defer { LoginManager.shared.removeLoginHeader(sourceUrl: key) }
            LoginManager.shared.storeLoginHeader(sourceUrl: key, raw: "synthetic-changed")
            var opened = false
            model.acceptConfirmation(owner: owner) { _ in opened = true }
            #expect(!opened)
            #expect(model.error != nil)
            do { try model.receive(input, source: source, owner: owner); Issue.record("旧凭据意图未拒绝") }
            catch { #expect(error is CancellationError) }
        }
    }
    @Test("真实附件意图保留文章身份；已删除和伪造附件不能启动或写入第二份URL进度")
    func attachmentRouteKeepsArticleIdentity() async throws {
        try await fixture { owner, source in
            var item = RSSItem(id: "fixture-media", title: "Media", link: source.url + "/article", sourceId: source.id)
            item.media = [.init(key: "attachment:0", articleID: item.id, kind: .video, url: source.url + "/stream.mp4?signature=one")]
            owner.mergeFetchedItems([item], for: source.id)
            let article = try #require(owner.article(id: item.id))
            let media = try #require(article.media?.first)
            let model = RSSWebActionRouter()
            model.playMedia(media, article: article, source: source, owner: owner)
            try await ready(model)
            guard case .video(_, let id, let key, let stream, let resources, _) = model.destination?.target else {
                Issue.record("附件未进入生产视频目的页"); return
            }
            defer { resources.stop() }
            #expect(id == article.id)
            #expect(key == media.key)
            #expect(stream.headers.isEmpty)
            let forged = RSSMediaReference(key: "other", articleID: article.id, kind: .video, url: source.url + "/arbitrary.mp4")
            let rejected = RSSWebActionRouter()
            rejected.playMedia(forged, article: article, source: source, owner: owner)
            #expect(rejected.error != nil)
            #expect(!rejected.isLoading && rejected.destination == nil)
        }
    }
    private func request(_ action: RSSWebAction, source: RSSSource, owner: RSSStore) -> RSSWebActionRequest {
        .init(action: action, authority: .page, sourceID: source.id, ownerID: owner.runtimeIdentity,
              ticket: owner.requestTicket(for: source.id), baseURL: URL(string: source.url),
              credentialRevision: LoginManager.shared.loginInfoRevision(sourceUrl: RSSRuntime.authenticationKey(for: source)))
    }
    private func ready(_ model: RSSWebActionRouter) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while model.isLoading, ContinuousClock.now < deadline { await Task.yield() }
        try #require(!model.isLoading)
        try #require(model.error == nil)
    }
    private func fixture(_ run: (RSSStore, RSSSource) async throws -> Void) async throws {
        let directory = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = RSSStore(storageDirectory: directory)
        let source = RSSSource(name: "Action fixture", url: "https://rss-fixture.invalid/" + UUID().uuidString)
        store.addSource(source)
        defer { do { try FileManager.default.removeItem(at: directory) } catch { Issue.record(error) } }
        do { try await run(store, source) }
        catch { try await store.flushPersistence(); throw error }
        try await store.flushPersistence()
    }
}
