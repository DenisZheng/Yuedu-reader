import Foundation
import Testing
@testable import yuedu_app

@Suite("订阅源布局与批量选择", .serialized)
struct RSSSourceBrowseTests {
    @Test("方格按分类筛选，包含停用源，保留sourceKey与稳定身份")
    func groupsAndIdentity() {
        let folder = RSSFolder(id: "news", name: "新闻")
        var first = RSSSource(id: "a", name: "甲", url: "https://fixture.invalid/#template,{options}", sortOrder: 2)
        first.sourceGroup = " 新闻 "
        var second = RSSSource(id: "b", name: "乙", url: "key-b", sortOrder: 0)
        second.enabled = false
        let input = [first, second]
        #expect(RSSSourceBrowse.sources(input, folders: [folder]).map(\.id) == ["b", "a"])
        #expect(RSSSourceBrowse.sources(input, folders: [folder], group: RSSSourceBrowse.folder(folder.id)) == [first])
        #expect(RSSSourceBrowse.sources(input, folders: [folder], group: RSSSourceBrowse.ungrouped) == [second])
        #expect(RSSSourceBrowse.sources(input, folders: [folder], query: "新闻") == [first])
        #expect(RSSSourceBrowse.sources(input, folders: [folder], unreadIDs: ["a"]) == [first])
    }

    @Test("全选当前列表保留其他分类的选择，批量删除不会按分类扩大范围")
    @MainActor func selectionAndDeletion() async throws {
        let folder = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = RSSStore(storageDirectory: folder)
        defer { do { try FileManager.default.removeItem(at: folder) } catch { Issue.record(error) } }
        let a = RSSSource(id: "a", name: "A", url: "key-a")
        var b = RSSSource(id: "b", name: "B", url: "key-b"); b.sourceGroup = "分组"
        let c = RSSSource(id: "c", name: "C", url: "key-c")
        _ = store.addSourcesReturningAdded([a, b, c])
        let aTicket = try #require(store.requestTicket(for: a.id))
        let bTicket = try #require(store.requestTicket(for: b.id))
        var selection = RSSSourceSelection(ids: [b.id])
        selection.toggleAll([a.id, c.id])
        #expect(selection.ids == [a.id, b.id, c.id])
        selection.toggleAll([a.id, c.id])
        #expect(selection.ids == [b.id])
        selection.ids.insert(a.id)
        store.removeSources(ids: Array(selection.ids))
        selection.retain(Set(store.sources.map(\.id)))
        #expect(selection.ids.isEmpty)
        #expect(store.sources.map(\.id) == [c.id])
        #expect(!store.accepts(aTicket) && !store.accepts(bTicket))
        // 分类仍在：源级批量操作不等于删分类。
        #expect(store.folders.map(\.name) == ["分组"])
        try await store.flushPersistence()
        let reloaded = RSSStore(storageDirectory: folder)
        #expect(reloaded.sources.map(\.id) == [c.id])
    }

    @Test("结果页全选和反选不会带入当前列表外的源")
    func resultPageSelection() {
        var selection = RSSSourceSelection(ids: ["hidden", "first"])
        let page: Set<String> = ["first", "second"]
        selection.toggleAll(page, onlyPage: true)
        #expect(selection.ids == page)
        selection.toggleAll(page, onlyPage: true)
        #expect(selection.ids.isEmpty)
        selection.ids = ["hidden", "first"]
        selection.invert(page)
        #expect(selection.ids == ["second"])
    }
}

@Suite("RSS活性验证", .serialized)
@MainActor struct RSSSourceHealthCheckerTests {
    private func fixture(_ body: (RSSStore, URLSession, String) async throws -> Void) async throws {
        let directory = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = RSSStore(storageDirectory: directory)
        let session = RSSPageFixtureProtocol.makeSession()
        let host = "rss-health-\(UUID().uuidString.lowercased()).invalid"
        defer {
            session.invalidateAndCancel(); RSSPageFixtureProtocol.remove(host: host)
            do { try FileManager.default.removeItem(at: directory) } catch { Issue.record(error) }
        }
        try await body(store, session, host)
        try await store.flushPersistence()
    }

    @Test("无搜索接口的规则源运行首分类首列表，不抓正文或写文章")
    func firstCategoryAndEmpty() async throws {
        try await fixture { store, session, host in
            RSSPageFixtureProtocol.serve(host: host, sequences: [
                "/list": [.init(body: Data("<a href='/article'>First</a>".utf8)), .init(body: Data("<main>No updates</main>".utf8))]
            ])
            var source = RSSSource(name: "分类规则", url: "https://\(host)/")
            source.sortUrl = "@js:'News::https://\(host)/list'"
            source.ruleArticles = "a"; source.ruleTitle = "text"; source.ruleLink = "href"
            source.ruleContent = "p@text"
            store.addSource(source)
            #expect(await RSSSourceHealthChecker.check(source: source, owner: store, session: session) == .list(1))
            #expect(store.articles(for: source.id).isEmpty)
            #expect(await RSSSourceHealthChecker.check(source: source, owner: store, session: session) == .emptyList)
            #expect(RSSPageFixtureProtocol.requests(host: host).map { $0.url?.path } == ["/list", "/list"])
        }
    }

    @Test("普通Feed走共享请求解析，HTTP错误不当空成功")
    func feedsAndHTTPFailure() async throws {
        try await fixture { store, session, host in
            let feed = """
            <?xml version="1.0"?><rss version="2.0"><channel><title>Fixture feed</title><link>https://\(host)/</link><description>Self-contained test feed</description><item><title>Article</title><link>https://\(host)/one</link><guid>one</guid></item></channel></rss>
            """
            RSSPageFixtureProtocol.serve(host: host, sequences: ["/feed": [
                .init(body: Data(feed.utf8)), .init(body: Data("fail".utf8), status: 503), .init(body: Data("login".utf8), status: 401)
            ]])
            let source = RSSSource(name: "Feed", url: "https://\(host)/feed")
            store.addSource(source)
            #expect(await RSSSourceHealthChecker.check(source: source, owner: store, session: session) == .list(1))
            let failed = await RSSSourceHealthChecker.check(source: source, owner: store, session: session)
            #expect(failed == .httpFailure(503))
            #expect(await RSSSourceHealthChecker.check(source: source, owner: store, session: session) == .interactionRequired)
        }
    }

    @Test("singleUrl优先运行动态入口；startHtml不冒充网络可达")
    func startupPriority() async throws {
        try await fixture { store, session, host in
            RSSPageFixtureProtocol.serve(host: host, contentType: "text/html", body: Data("<html><body>Player page</body></html>".utf8))
            var source = RSSSource(name: "动态网页", url: "https://\(host)/")
            source.singleUrl = true; source.sortUrl = "@js:'https://\(host)/start'"
            source.startHtml = "<p>Should not take precedence</p>"
            store.addSource(source)
            #expect(await RSSSourceHealthChecker.check(source: source, owner: store, session: session) == .webReachable)
            #expect(RSSPageFixtureProtocol.requests(host: host).map { $0.url?.path } == ["/start"])
            source.singleUrl = false; source.sortUrl = nil
            store.updateSource(source)
            #expect(await RSSSourceHealthChecker.check(source: source, owner: store, session: session) == .generatedPage)
            #expect(RSSPageFixtureProtocol.requests(host: host).count == 1)
        }
    }

    @Test("已知媒体入口不下载资源，也不报告影片可播")
    func directMediaNeedsPlaybackCheck() async throws {
        try await fixture { store, session, host in
            var source = RSSSource(name: "Media", url: "https://\(host)/video.mp4")
            source.singleUrl = true; source.importedFromLegado = true
            store.addSource(source)
            #expect(await RSSSourceHealthChecker.check(source: source, owner: store, session: session) == .mediaEntry)
            #expect(RSSPageFixtureProtocol.requests(host: host).isEmpty)
        }
    }

    @Test("cacheFirst不能令活性检查复用第一次成功结果")
    func checkBypassesCacheFirst() async throws {
        try await fixture { store, session, host in
            RSSPageFixtureProtocol.serve(host: host, sequences: ["/start": [
                .init(body: Data("<html><body>Available</body></html>".utf8)),
                .init(body: Data("Unavailable".utf8), status: 503)
            ]])
            var source = RSSSource(name: "Cached web", url: "https://\(host)/start")
            source.singleUrl = true; source.cacheFirst = true; source.importedFromLegado = true
            store.addSource(source)
            #expect(await RSSSourceHealthChecker.check(source: source, owner: store, session: session) == .webReachable)
            let next = await RSSSourceHealthChecker.check(source: source, owner: store, session: session)
            #expect(next == .httpFailure(503), "缓存不能掩盖第二次入口503")
            #expect(RSSPageFixtureProtocol.requests(host: host).count == 2)
        }
    }

    @Test("诊断可检查停用源但不启用它，普通读取仍拒绝停用票据")
    func disabledSourceDiagnostic() async throws {
        try await fixture { store, session, host in
            var source = RSSSource(name: "Disabled", url: "https://\(host)/")
            source.enabled = false
            source.startHtml = "<html><body>Generated diagnostic</body></html>"
            store.addSource(source)
            let ticket = try #require(store.requestTicket(for: source.id))
            #expect(!store.accepts(ticket))
            #expect(await RSSSourceHealthChecker.check(source: source, owner: store, session: session) == .generatedPage)
            #expect(store.source(id: source.id)?.enabled == false)
            #expect(!store.accepts(ticket))
        }
    }

    @Test("批次取消不继续下一源；删除后释放旧响应也不能留下结果")
    func batchCancellationAndLateResult() async throws {
        try await fixture { store, session, host in
            let (events, continuation) = AsyncStream<URLRequest>.makeStream()
            defer { continuation.finish() }
            RSSPageFixtureProtocol.serve(host: host, sequences: [
                "/held": [.init(body: Data("<a href='/one'>One</a>".utf8), held: true)],
                "/second": [.init(body: Data("<a href='/two'>Two</a>".utf8))]
            ], events: continuation)
            var first = RSSSource(name: "First", url: "https://\(host)/held")
            first.ruleArticles = "a"; first.ruleTitle = "text"; first.ruleLink = "href"
            var second = first; second.id = "second"; second.url = "https://\(host)/second"
            _ = store.addSourcesReturningAdded([first, second])
            let checker = RSSSourceHealthChecker()
            checker.start(sources: [first, second], owner: store, session: session)
            var iterator = events.makeAsyncIterator()
            #expect(await iterator.next() != nil)
            checker.cancel()
            await checker.waitForCompletion()
            #expect(!checker.isRunning)
            #expect(checker.results[first.id] == .cancelled)
            #expect(RSSPageFixtureProtocol.requests(host: host).count == 1)
            store.removeSources(ids: [first.id])
            RSSPageFixtureProtocol.release(host: host)
            checker.retainResults(for: store.sources)
            #expect(checker.results[first.id] == nil)
            #expect(store.articles(for: first.id).isEmpty)
        }
    }

    @Test("只汇总当前列表的有效结果，成功、失败、未检查以及过期结果不混用")
    func selectionGroupsAreScopedAndCurrent() async throws {
        try await fixture { store, session, host in
            RSSPageFixtureProtocol.serve(host: host, sequences: [
                "/failed": [.init(body: Data(), status: 503)],
                "/empty": [.init(body: Data("<main>Empty</main>".utf8))],
                "/login": [.init(body: Data(), status: 401)]
            ])
            let failed = RSSSource(id: "failure", name: "Failure", url: "https://\(host)/failed")
            var empty = RSSSource(id: "empty", name: "Empty", url: "https://\(host)/empty")
            empty.ruleArticles = "class.item"
            let login = RSSSource(id: "login", name: "Login", url: "https://\(host)/login")
            let unchecked = RSSSource(id: "unchecked", name: "Unchecked", url: "https://\(host)/unchecked")
            for source in [failed, empty, login, unchecked] { store.addSource(source) }
            let checker = RSSSourceHealthChecker()
            checker.start(sources: [failed, empty, login], owner: store, session: session)
            await checker.waitForCompletion()
            let revisions = try #require(store.requestRevisions)
            let groups = await checker.selectionGroups(in: [failed, empty, unchecked], revisions: revisions)
            #expect(groups.map(\.kind) == [.httpFailure(503), .emptyList])
            #expect(groups.map(\.sourceIDs) == [[failed.id], [empty.id]])

            store.authenticationChanged(for: failed.id)
            try store.setSourceVariableJSON("{}", for: empty.id)
            let fresh = try #require(store.requestRevisions)
            let remaining = await checker.selectionGroups(in: store.sources, revisions: fresh)
            #expect(remaining.map(\.kind) == [.interactionRequired])
            #expect(remaining.map(\.sourceIDs) == [[login.id]])
        }
    }

    @Test("真实HTTP响应码分组，404的全选范围不混入423、503或其他失败")
    func httpFailuresHaveTheirOwnScopedGroups() async throws {
        try await fixture { store, session, host in
            let routes = [("gone-a", 404), ("locked", 423), ("gone-b", 404), ("busy", 503),
                          ("not-a-feed", 200), ("auth", 401), ("forbidden", 403)]
            RSSPageFixtureProtocol.serve(host: host, sequences: Dictionary(uniqueKeysWithValues: routes.map { route, code in
                ("/" + route, [.init(body: Data("Fixture response".utf8), status: code)])
            }))
            let sources = store.addSourcesReturningAdded(routes.map { route, _ in
                RSSSource(name: route, url: "https://\(host)/\(route)")
            })
            try #require(sources.count == routes.count)
            let checker = RSSSourceHealthChecker()
            checker.start(sources: sources, owner: store, session: session)
            await checker.waitForCompletion()

            let revisions = try #require(store.requestRevisions)
            let groups = await checker.selectionGroups(in: sources, revisions: revisions)
            #expect(groups.first { $0.kind.title == "HTTP 404" }?.sourceIDs == [sources[0].id, sources[2].id])
            #expect(groups.first { $0.kind.title == "HTTP 423" }?.sourceIDs == [sources[1].id])
            #expect(groups.first { $0.kind.title == "HTTP 503" }?.sourceIDs == [sources[3].id])
            #expect(groups.first { $0.kind == .failed }?.sourceIDs == [sources[4].id])
            #expect(groups.first { $0.kind == .interactionRequired }?.sourceIDs == [sources[5].id, sources[6].id])
            #expect(groups.count == 5)

            let scoped = RSSSourceBrowse.sources(sources, folders: [], query: "gone-a")
            let visible = await checker.selectionGroups(in: scoped, revisions: revisions)
            var selection = RSSSourceSelection(ids: [sources[1].id])
            let matches404 = visible.first { $0.kind.title == "HTTP 404" }?.sourceIDs ?? []
            selection.toggleAll(matches404, onlyPage: true)
            #expect(selection.ids == [sources[0].id], "结果页的全选只取当前搜索范围内的404")
        }
    }

    @Test("重查后取消，尚未轮到的源不沿用上次失败结果")
    func cancelledRecheckDoesNotOfferOldFailures() async throws {
        try await fixture { store, session, host in
            RSSPageFixtureProtocol.serve(host: host, sequences: [
                "/first": [.init(body: Data(), status: 503)],
                "/later": [.init(body: Data(), status: 503)]
            ])
            let first = RSSSource(id: "first", name: "First", url: "https://\(host)/first")
            let later = RSSSource(id: "later", name: "Later", url: "https://\(host)/later")
            store.addSource(first); store.addSource(later)
            let checker = RSSSourceHealthChecker()
            checker.start(sources: [first, later], owner: store, session: session)
            await checker.waitForCompletion()
            #expect(checker.results[later.id]?.kind == .httpFailure(503))

            let (events, continuation) = AsyncStream<URLRequest>.makeStream()
            defer { continuation.finish() }
            RSSPageFixtureProtocol.serve(host: host, sequences: [
                "/first": [.init(body: Data(), held: true)]
            ], events: continuation)
            checker.start(sources: [first, later], owner: store, session: session)
            var iterator = events.makeAsyncIterator()
            try #require(await iterator.next() != nil)
            checker.cancel()
            await checker.waitForCompletion()
            #expect(checker.results[first.id] == .cancelled)
            #expect(checker.results[later.id] == nil)
            let groups = await checker.selectionGroups(in: store.sources, revisions: try #require(store.requestRevisions))
            #expect(groups.map(\.kind) == [.cancelled])
        }
    }

    @Test("两个不同主机的普通Feed同时在途，取消时第三个不发送")
    func differentFeedHostsOverlapAndCancelAllActive() async throws {
        try await fixture { store, session, host in
            let hosts = [host, "second-" + host, "queued-" + host]
            let (events, continuation) = AsyncStream<URLRequest>.makeStream()
            defer {
                continuation.finish()
                for host in hosts { RSSPageFixtureProtocol.remove(host: host) }
            }
            let sources = store.addSourcesReturningAdded(hosts.map { RSSSource(name: "Held feed", url: "https://\($0)/feed") })
            try #require(sources.count == hosts.count)
            for host in hosts {
                RSSPageFixtureProtocol.serve(host: host, sequences: ["/feed": [.init(body: Self.feedBody, held: true)]], events: continuation)
            }
            let checker = RSSSourceHealthChecker()
            checker.start(sources: sources, owner: store, session: session)
            let started = await Self.startedHosts(in: events, count: 2)
            checker.cancel()
            await checker.waitForCompletion()
            for host in hosts { RSSPageFixtureProtocol.release(host: host) }

            #expect(started == Set(hosts.prefix(2)), "第二个主机须在第一个未响应时就收到请求")
            #expect(checker.results[sources[0].id] == .cancelled)
            #expect(checker.results[sources[1].id] == .cancelled)
            #expect(checker.results[sources[2].id] == nil)
            #expect(!checker.isRunning && checker.completed == 0)
            #expect(hosts.map { RSSPageFixtureProtocol.requests(host: $0).count } == [1, 1, 0])
        }
    }

    enum SerialBoundary: CaseIterable, Sendable { case sameHost, discoveredHost, rule, login, scriptInDiscoveredURL }

    @Test("同一目标主机、规则、登录和动态URL都不能带着下一源一起开始", arguments: SerialBoundary.allCases)
    func aSerialBoundaryDoesNotStartTheNextSource(_ boundary: SerialBoundary) async throws {
        try await fixture { store, session, host in
            let alias = "alias-" + host
            var first = RSSSource(name: "First", url: "https://\(host)/feed")
            let nextHost: String
            switch boundary {
            case .sameHost: nextHost = host
            case .discoveredHost:
                first.url = "https://\(alias)/landing"
                first.resolvedFeedURL = "https://\(host)/feed"
                nextHost = host
            case .rule: first.ruleArticles = "item"; nextHost = alias
            case .login: first.loginUrl = "https://\(host)/sign-in"; nextHost = alias
            case .scriptInDiscoveredURL:
                first.resolvedFeedURL = "https://\(host)/feed<js>result</js>"
                nextHost = alias
            }
            let next = RSSSource(name: "Next", url: "https://\(nextHost)/next")
            store.addSource(first); store.addSource(next)
            let (events, continuation) = AsyncStream<URLRequest>.makeStream()
            defer { continuation.finish(); RSSPageFixtureProtocol.remove(host: alias) }
            RSSPageFixtureProtocol.serve(host: host, sequences: [
                "/feed": [.init(body: Self.feedBody, held: true)], "/next": [.init(body: Self.feedBody, held: true)]
            ], events: continuation)
            RSSPageFixtureProtocol.serve(host: alias, sequences: [
                "/next": [.init(body: Self.feedBody, held: true)]
            ], events: continuation)
            let checker = RSSSourceHealthChecker()
            checker.start(sources: [first, next], owner: store, session: session)
            let started = await Self.startedHosts(in: events, count: 1)
            checker.cancel()
            await checker.waitForCompletion()

            #expect(started == [host])
            #expect(checker.results[first.id] == .cancelled)
            #expect(checker.results[next.id] == nil)
            #expect(RSSPageFixtureProtocol.requests(host: host).map { $0.url?.path } == ["/feed"])
            #expect(RSSPageFixtureProtocol.requests(host: alias).isEmpty)
        }
    }

    @Test("并行检查中改登录或删源，晚到结果不进入结果页")
    func changingLoginAndDeletingDuringParallelCheck() async throws {
        try await fixture { store, session, host in
            let secondHost = "deleted-" + host
            let (events, continuation) = AsyncStream<URLRequest>.makeStream()
            defer { continuation.finish(); RSSPageFixtureProtocol.remove(host: secondHost) }
            for host in [host, secondHost] {
                RSSPageFixtureProtocol.serve(host: host, sequences: [
                    "/feed": [.init(body: Self.feedBody, held: true)]
                ], events: continuation)
            }
            let first = RSSSource(name: "Login changed", url: "https://\(host)/feed")
            let second = RSSSource(name: "Deleted", url: "https://\(secondHost)/feed")
            store.addSource(first); store.addSource(second)
            let checker = RSSSourceHealthChecker()
            checker.start(sources: [first, second], owner: store, session: session)
            let started = await Self.startedHosts(in: events, count: 2)
            if started != [host, secondHost] { checker.cancel() }
            store.authenticationChanged(for: first.id)
            store.removeSources(ids: [second.id])
            RSSPageFixtureProtocol.release(host: host)
            RSSPageFixtureProtocol.release(host: secondHost)
            await checker.waitForCompletion()

            #expect(started == [host, secondHost])
            #expect(checker.results.isEmpty)
            #expect(!checker.isRunning)
            let revisions = try #require(store.requestRevisions)
            #expect(await checker.selectionGroups(in: [first, second], revisions: revisions).isEmpty)
        }
    }

    @Test("不同主机启动后，跨主机重定向在已有请求结束后继续，不重发入口")
    func redirectWaitsForTheActualHost() async throws {
        try await fixture { store, session, _ in
            let server = try VideoStillFixtureServer(directory: .temporaryDirectory, maximumRequests: 3)
            let base = try await server.start()
            defer { server.stop() }
            let direct = base.appendingPathComponent("slow")
            let final = base.appendingPathComponent("final")
            var alias = URLComponents(url: base.appendingPathComponent("redirect"), resolvingAgainstBaseURL: false)
            alias?.host = "localhost"
            let redirected = try #require(alias?.url)

            let delay = Duration.seconds(1)
            let clock = ContinuousClock()
            let (waitingForDirect, directStarted) = AsyncStream<Void>.makeStream()
            let (events, arrival) = AsyncStream<(String, ContinuousClock.Instant)>.makeStream()
            defer { directStarted.finish(); arrival.finish() }
            server.observeRequests { request in
                arrival.yield((request.path, clock.now))
                if request.path == "/slow" { directStarted.yield(()) }
            }
            let feed = Self.feedBody
            server.route { request in
                switch request.path {
                case "/slow":
                    return .init(body: feed, beforeSending: { try await Task.sleep(for: delay) })
                case "/redirect":
                    return .init(body: Data(), status: "302 Found", headers: ["Location": final.absoluteString], beforeSending: {
                        var iterator = waitingForDirect.makeAsyncIterator()
                        guard await iterator.next() != nil else { throw CancellationError() }
                    })
                case "/final": return .init(body: feed)
                default: return .init(body: Data(), status: "404 Not Found")
                }
            }

            let a = RSSSource(name: "Direct", url: direct.absoluteString)
            let b = RSSSource(name: "Redirected", url: redirected.absoluteString)
            store.addSource(a); store.addSource(b)
            let checker = RSSSourceHealthChecker()
            checker.start(sources: [a, b], owner: store, session: session)
            await checker.waitForCompletion()
            arrival.finish()
            var times: [String: ContinuousClock.Instant] = [:]
            for await (path, time) in events { times[path] = time }

            let directAt = try #require(times["/slow"])
            let redirectAt = try #require(times["/redirect"])
            let finalAt = try #require(times["/final"])
            #expect(redirectAt < directAt.advanced(by: delay), "另一个主机的入口应可并行发出")
            #expect(directAt.duration(to: finalAt) >= delay, "跳转后的请求必须等待目标主机空出")
            #expect(server.requests.map(\.path).sorted() == ["/final", "/redirect", "/slow"])
            #expect(checker.results[a.id] == .list(1) && checker.results[b.id] == .list(1))
        }
    }

    @Test("六个不同主机的等候响应：验证结果和请求数，记录批次耗时")
    func plainFeedBatchTiming() async throws {
        try await fixture { store, session, host in
            let hosts = (1...6).map { "feed\($0)-" + host }
            let (events, continuation) = AsyncStream<URLRequest>.makeStream()
            defer {
                continuation.finish()
                for host in hosts { RSSPageFixtureProtocol.remove(host: host) }
            }
            let sources = store.addSourcesReturningAdded(hosts.map { RSSSource(name: "Timed feed", url: "https://\($0)/feed") })
            try #require(sources.count == hosts.count)
            for host in hosts {
                RSSPageFixtureProtocol.serve(host: host, sequences: ["/feed": [.init(body: Self.feedBody, held: true)]], events: continuation)
            }
            let responder = Task {
                try await withThrowingTaskGroup(of: Void.self) { group in
                    for await request in events {
                        guard let host = request.url?.host else { continue }
                        group.addTask {
                            // 固定模拟服务器响应耗时；不是等待被测状态稳定。
                            try await Task.sleep(for: .milliseconds(500))
                            RSSPageFixtureProtocol.release(host: host)
                        }
                    }
                    try await group.waitForAll()
                }
            }
            let checker = RSSSourceHealthChecker()
            let clock = ContinuousClock()
            let start = clock.now
            checker.start(sources: sources, owner: store, session: session)
            await checker.waitForCompletion()
            let elapsed = start.duration(to: clock.now)
            continuation.finish()
            try await responder.value

            let requestCount = hosts.map { RSSPageFixtureProtocol.requests(host: $0).count }.reduce(0, +)
            print("RSS fixture: sources=\(sources.count) delay=500ms requests=\(requestCount) elapsed=\(elapsed)")
            #expect(checker.completed == sources.count)
            #expect(sources.allSatisfy { checker.results[$0.id] == .list(1) && store.articles(for: $0.id).isEmpty })
            #expect(hosts.allSatisfy { RSSPageFixtureProtocol.requests(host: $0).count == 1 })
        }
    }

    private static let feedBody = Data("""
        <rss version="2.0"><channel><title>Fixture</title><link>https://fixture.invalid/</link>
        <description>Local response</description><item><title>One</title><link>/one</link><guid>one</guid></item>
        </channel></rss>
        """.utf8)

    private nonisolated static func startedHosts(in events: AsyncStream<URLRequest>, count: Int) async -> Set<String>? {
        await withTaskGroup(of: Set<String>?.self) { group in
            group.addTask {
                var hosts: Set<String> = []
                for await request in events {
                    if let host = request.url?.host { hosts.insert(host) }
                    if hosts.count == count { return hosts }
                }
                return nil
            }
            group.addTask {
                // 限定回归失败的等待时间，不用延时判断正常顺序。
                do { try await Task.sleep(for: .seconds(5)) } catch { return nil }
                return nil
            }
            let result = await group.next() ?? nil
            group.cancelAll()
            return result
        }
    }

    @Test("整体超时取消在途请求，已删源不能留下晚到结果")
    func timeoutAndDeletion() async throws {
        try await fixture { store, session, host in
            RSSPageFixtureProtocol.serve(host: host, sequences: ["/held": [.init(body: Data("held".utf8), held: true)]])
            let source = RSSSource(name: "Timeout", url: "https://\(host)/held")
            store.addSource(source)
            #expect(await RSSSourceHealthChecker.check(source: source, owner: store, session: session, timeout: .milliseconds(50)) == .failed(localized("校驗超時")))
            store.removeSources(ids: [source.id])
            #expect(await RSSSourceHealthChecker.check(source: source, owner: store, session: session) == .cancelled)
            #expect(store.sources.isEmpty)
        }
    }
}
