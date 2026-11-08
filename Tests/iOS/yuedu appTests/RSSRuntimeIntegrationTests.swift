import Foundation
import Testing
@testable import yuedu_app

@Suite("S4 RSS runtime integration", .serialized, .timeLimit(.minutes(1)))
@MainActor
struct RSSRuntimeIntegrationTests {
    @Test("源变量落盘/重载，JS全局连续，不变不写")
    func sourceLifetimeAndPersistence() async throws {
        try await withStore { store, directory in
            let host = hostName()
            let session = RSSPageFixtureProtocol.makeSession()
            RSSPageFixtureProtocol.serve(host: host, contentType: "text/html", body: html)
            defer { session.invalidateAndCancel(); RSSPageFixtureProtocol.remove(host: host) }
            var source = rules(host: host)
            source.jsLib = "var count = 0; java.put('persistent', 'value');"
            source.ruleTitle = "@js: source.setVariable('opaque'); java.get('persistent') + '|' + source.getVariable() + '|' + (++count)"
            store.addSource(source)
            let one = try await LegadoRSSScraper.scrape(source: source, owner: store, requestSession: session)
            let two = try await LegadoRSSScraper.scrape(source: source, owner: store, requestSession: session)
            #expect(one.first?.title == "value|opaque|1")
            #expect(two.first?.title == "value|opaque|2")
            #expect(store.variables(for: source.id) == ["persistent": "value"])
            try await store.flushPersistence()
            let writes = store.writeCounts
            _ = try await LegadoRSSScraper.scrape(source: source, owner: store, requestSession: session)
            try await store.flushPersistence()
            #expect(store.writeCounts == writes)
            let reloaded = RSSStore(storageDirectory: directory)
            #expect(try reloaded.runtimeSnapshot(for: source).variableJSON == "opaque")
            let fresh = try await LegadoRSSScraper.scrape(source: source, owner: reloaded, requestSession: session)
            #expect(fresh.first?.title == "value|opaque|1")
            try await reloaded.flushPersistence()
        }
    }

    @Test("URL和规则阶段的bindings不互漏，文章读到本次URL变量")
    func requestAndRuleBindings() async throws {
        let host = hostName()
        let session = RSSPageFixtureProtocol.makeSession()
        RSSPageFixtureProtocol.serve(host: host, contentType: "text/html", body: html)
        defer { session.invalidateAndCancel(); RSSPageFixtureProtocol.remove(host: host) }
        var source = rules(host: host)
        source.url = "@js:java.put('urlPhase', typeof rssArticle + ':' + page); 'https://\(host)/list'"
        source.ruleTitle = "@js: java.get('urlPhase') + '|' + typeof page + '|' + typeof key + '|' + typeof rssArticle"
        let one = try await LegadoRSSScraper.scrape(source: source, page: 1, requestSession: session)
        let two = try await LegadoRSSScraper.scrape(source: source, page: 2, requestSession: session)
        #expect(one.first?.title == "undefined:1|undefined|undefined|object")
        #expect(two.first?.title == "undefined:2|undefined|undefined|object")
    }

    @Test("源/登录头按目标隔离，URL options优先，显式跨域头仍有效")
    func scopedHeaders() async throws {
        let host = hostName()
        let external = hostName()
        let session = RSSPageFixtureProtocol.makeSession()
        RSSPageFixtureProtocol.serve(host: host, contentType: "text/html", body: html)
        RSSPageFixtureProtocol.serve(host: external, contentType: "text/plain", body: Data("ok".utf8))
        var source = rules(host: host)
        source.url += #",{"headers":{"authorization":"option"}}"#
        source.header = #"{"authorization":"source","X-Private":"private","Cookie":"inline=one","User-Agent":"Fixture"}"#
        source.ruleTitle = """
        @js: java.ajax('https://\(external)/auto');
        java.ajax('https://\(external)/explicit,{"headers":{"X-Private":"explicit"}}'); 'Done'
        """
        let key = RSSRuntime.authenticationKey(for: source)
        LoginManager.shared.storeLoginHeader(sourceUrl: key, raw: #"{"Authorization":"login"}"#)
        defer {
            session.invalidateAndCancel()
            RSSPageFixtureProtocol.remove(host: host); RSSPageFixtureProtocol.remove(host: external)
            LoginManager.shared.clearLogin(sourceUrl: key)
        }
        let items = try await LegadoRSSScraper.scrape(source: source, requestSession: session)
        #expect(items.first?.title == "Done")
        let primary = try #require(RSSPageFixtureProtocol.requests(host: host).first)
        #expect(primary.value(forHTTPHeaderField: "Authorization") == "option")
        #expect(primary.value(forHTTPHeaderField: "X-Private") == "private")
        let others = RSSPageFixtureProtocol.requests(host: external)
        #expect(others.count == 2)
        #expect(others.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == nil && $0.value(forHTTPHeaderField: "Cookie") == nil })
        #expect(others.first?.value(forHTTPHeaderField: "X-Private") == nil)
        #expect(others.last?.value(forHTTPHeaderField: "X-Private") == "explicit")
    }

    @Test("java.ajaxAll实际请求遵守每源速率且保持返回顺序")
    func scriptRateLimit() async throws {
        let host = hostName()
        let session = RSSPageFixtureProtocol.makeSession()
        RSSPageFixtureProtocol.serve(host: host, sequences: [
            "/list": [.init(body: html)],
            "/a": [.init(body: Data("A".utf8))], "/b": [.init(body: Data("B".utf8))], "/c": [.init(body: Data("C".utf8))]
        ])
        defer { session.invalidateAndCancel(); RSSPageFixtureProtocol.remove(host: host) }
        var source = rules(host: host)
        source.concurrentRate = "1/120"
        source.ruleTitle = "@js: java.ajaxAll(['https://\(host)/a','https://\(host)/b','https://\(host)/c']).map(x=>x.body()).join(',')"
        let items = try await LegadoRSSScraper.scrape(source: source, requestSession: session)
        #expect(items.first?.title == "A,B,C")
        let times = RSSPageFixtureProtocol.requestTimes(host: host)
        #expect(times.count == 4)
        #expect(try #require(times.last).timeIntervalSince(try #require(times.first)) >= 0.25)
    }

    @Test("Cookie请求不取兄弟host或其他path；关闭CookieJar仍允许显式Cookie")
    func cookieScope() async throws {
        let host = hostName()
        let session = RSSPageFixtureProtocol.makeSession()
        let privateCookie = try #require(HTTPCookie(properties: [.name: "private", .value: "one", .domain: host, .path: "/private"]))
        let childCookie = try #require(HTTPCookie(properties: [.name: "child", .value: "two", .domain: "child." + host, .path: "/"]))
        HTTPCookieStorage.shared.setCookie(privateCookie)
        HTTPCookieStorage.shared.setCookie(childCookie)
        RSSPageFixtureProtocol.serve(host: host, contentType: "text/html", body: html)
        defer {
            session.invalidateAndCancel(); RSSPageFixtureProtocol.remove(host: host)
            HTTPCookieStorage.shared.deleteCookie(privateCookie); HTTPCookieStorage.shared.deleteCookie(childCookie)
        }
        var source = rules(host: host)
        source.enabledCookieJar = false
        source.header = #"{"Cookie":"explicit=ok"}"#
        _ = try await LegadoRSSScraper.scrape(source: source, requestSession: session)
        let request = try #require(RSSPageFixtureProtocol.requests(host: host).first)
        #expect(request.value(forHTTPHeaderField: "Cookie") == "explicit=ok")
        #expect(!request.httpShouldHandleCookies)
        let privateURL = try #require(URL(string: "https://\(host)/private/content"))
        #expect(CookieStore.shared.requestHeader(for: privateURL).contains("private=one"))
    }

    @Test("坏jsLib在网络前失败；诊断不保存源日志/异常/响应中的任意私密串")
    func scriptFailureAndRedaction() async throws {
        let host = hostName()
        let session = RSSPageFixtureProtocol.makeSession()
        RSSPageFixtureProtocol.serve(host: host, contentType: "text/html", body: html)
        defer { session.invalidateAndCancel(); RSSPageFixtureProtocol.remove(host: host) }
        var source = rules(host: host)
        let secret = "fixture-private-" + UUID().uuidString
        source.jsLib = "java.log('\(secret)'); throw new Error('\(secret)');"
        let before = Set(DiagnosticLog.shared.snapshot().map(\.id))
        do {
            _ = try await LegadoRSSScraper.scrape(source: source, requestSession: session)
            Issue.record("坏jsLib不能返回成功")
        } catch ScraperError.scriptFailure { }
        #expect(RSSPageFixtureProtocol.requests(host: host).isEmpty)
        let entries = DiagnosticLog.shared.snapshot().filter { !before.contains($0.id) }
        #expect(!entries.isEmpty)
        #expect(entries.allSatisfy { !($0.message + ($0.detail ?? "")).contains(secret) })
    }

    @Test("配置修订使旧请求脚本失效，不得写入新的登录状态")
    func configurationInvalidationStopsLateScripts() async throws {
        try await withStore { store, _ in
            let host = hostName()
            let session = RSSPageFixtureProtocol.makeSession()
            let (events, continuation) = AsyncStream<URLRequest>.makeStream()
            RSSPageFixtureProtocol.serve(host: host, sequences: ["/list": [.init(body: html, held: true)]], events: continuation)
            var source = rules(host: host)
            source.ruleTitle = "@js: source.putLoginHeader('stale'); java.put('late', 'bad'); 'Late'"
            store.addSource(source)
            let key = RSSRuntime.authenticationKey(for: source)
            defer {
                session.invalidateAndCancel(); continuation.finish(); RSSPageFixtureProtocol.remove(host: host)
                LoginManager.shared.clearLogin(sourceUrl: key)
            }
            let snapshot = source
            let task = Task { try await LegadoRSSScraper.scrape(source: snapshot, owner: store, requestSession: session) }
            var iterator = events.makeAsyncIterator()
            #expect(await iterator.next() != nil)
            // 迫使全局32项LRU淘汰正在请求的会话；owner的弱登记仍必须能撤销它。
            for _ in 0..<34 {
                _ = try await RSSRuntime.make(source: rules(host: hostName()), requestSession: session)
            }
            source.ruleTitle = "a@text"
            store.updateSource(source)
            // 不释放响应：配置变更必须主动取消实际请求，不能等到HTTP完成才丢弃结果。
            do { _ = try await task.value; Issue.record("旧请求不能成功") }
            catch is CancellationError { }
            RSSPageFixtureProtocol.release(host: host)
            #expect(LoginManager.shared.getLoginHeader(sourceUrl: key) == nil)
            #expect(store.variables(for: source.id)["late"] == nil)
        }
    }

    @Test("后台浏览器/验证码/WebView/搜索请求返回需交互，不展示或联网")
    func backgroundInteractionIsExplicit() async throws {
        let host = hostName()
        let session = RSSPageFixtureProtocol.makeSession()
        RSSPageFixtureProtocol.serve(host: host, contentType: "text/html", body: html)
        defer { session.invalidateAndCancel(); RSSPageFixtureProtocol.remove(host: host) }
        for script in [
            "java.startBrowserAwait('https://\(host)/login','Fixture')",
            "java.getVerificationCode('https://\(host)/captcha')",
            "java.webView(null, 'https://\(host)/web', null)",
            "java.searchBook('fixture')"
        ] {
            var source = rules(host: host)
            source.jsLib = script
            do { _ = try await LegadoRSSScraper.scrape(source: source, requestSession: session); Issue.record("未报告需交互") }
            catch ScraperError.interactionRequired { }
        }
        var webOption = rules(host: host)
        webOption.url += #",{"webView":true}"#
        do { _ = try await LegadoRSSScraper.scrape(source: webOption, requestSession: session); Issue.record("WebView选项不能当普通HTTP") }
        catch ScraperError.interactionRequired { }
        #expect(RSSPageFixtureProtocol.requests(host: host).isEmpty)
    }

    @Test("登录revision的旧写入被拒绝，删除登录头保留凭据")
    func credentialCompareAndSet() async throws {
        var source = rules(host: hostName())
        source.sortUrl = #"@js: source.putLoginInfo('{"user":"fixture"}'); source.putLoginHeader('one'); source.removeLoginHeader(); 'One::https://fixture.invalid/'"#
        let key = RSSRuntime.authenticationKey(for: source)
        defer { LoginManager.shared.clearLogin(sourceUrl: key) }
        _ = try await LegadoRSSScraper.resolveSortEntries(for: source)
        #expect(LoginManager.shared.getLoginInfo(sourceUrl: key)?["user"] == "fixture")
        #expect(LoginManager.shared.getLoginHeader(sourceUrl: key) == nil)
        let previous = LoginManager.shared.loginInfoRevision(sourceUrl: key)
        LoginManager.shared.storeLoginHeader(sourceUrl: key, raw: "new")
        #expect(LoginManager.shared.storeLoginHeader(sourceUrl: key, raw: "stale", expectedRevision: previous) == nil)
        #expect(LoginManager.shared.getLoginHeader(sourceUrl: key) == "new")
        var changed = source
        changed.url += "#new-key"
        #expect(RSSRuntime.authenticationKey(for: changed) != key)
    }

    @Test("运行变量文件兼容S3并保留opaque值，拒绝未来版本")
    func runtimeFileCompatibility() throws {
        let old = Data(#"{"source":{"item":"value"},"schemaVersion":{"old":"source-key"}}"#.utf8)
        let decoded = try JSONDecoder().decode(RSSRuntimeStateFile.self, from: old)
        #expect(decoded.values["source"]?["item"] == "value")
        #expect(decoded.values["schemaVersion"]?["old"] == "source-key")
        var upgraded = decoded
        upgraded.options["source"] = "opaque"
        let encoded = try JSONEncoder().encode(upgraded)
        let restored = try JSONDecoder().decode(RSSRuntimeStateFile.self, from: encoded)
        #expect(restored.schemaVersion == 1 && restored.options["source"] == "opaque")
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(RSSRuntimeStateFile.self, from: Data(#"{"schemaVersion":2,"values":{},"options":{}}"#.utf8))
        }
    }

    @Test("真实HTTP重定向到另一origin时不带源私有头或手工Cookie")
    func redirectDoesNotLeakHeaders() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("rss-redirect-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { do { try FileManager.default.removeItem(at: directory) } catch { Issue.record(error) } }
        let destination = try VideoStillFixtureServer(directory: directory, routes: ["/finish": .init(body: html)])
        let destinationURL = try await destination.start()
        defer { destination.stop() }
        let origin = try VideoStillFixtureServer(directory: directory, routes: [
            "/start": .init(body: Data(), status: "302 Found", headers: ["Location": destinationURL.appendingPathComponent("finish").absoluteString])
        ])
        let originURL = try await origin.start()
        defer { origin.stop() }
        var source = rules(host: "unused.invalid")
        source.url = originURL.appendingPathComponent("start").absoluteString
        source.header = #"{"X-Private":"private","Authorization":"private","Cookie":"inline_fixture=one","User-Agent":"RSSFixture"}"#
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil; config.urlCredentialStorage = nil
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let items = try await LegadoRSSScraper.scrape(source: source, requestSession: session)
        #expect(items.first?.title == "One")
        #expect(origin.requests.first?.headers["x-private"] == "private")
        let final = try #require(destination.requests.first)
        #expect(final.headers["x-private"] == nil && final.headers["authorization"] == nil)
        #expect(final.headers["cookie"]?.contains("inline_fixture=one") != true)
        #expect(final.headers["user-agent"] == "RSSFixture")
    }

    @Test("CookieJar关闭不保存响应Cookie，开启才保存；两种情况均保留手工Cookie")
    func responseCookieJarSwitch() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("rss-cookie-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { do { try FileManager.default.removeItem(at: directory) } catch { Issue.record(error) } }
        let cookieName = "rss_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let server = try VideoStillFixtureServer(directory: directory, routes: [
            "/list": .init(body: html, headers: ["Set-Cookie": "\(cookieName)=yes; Path=/"])
        ])
        let base = try await server.start()
        defer {
            server.stop()
            for cookie in HTTPCookieStorage.shared.cookies ?? [] where cookie.name == cookieName {
                HTTPCookieStorage.shared.deleteCookie(cookie)
            }
        }
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = .shared
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        var source = rules(host: "unused.invalid")
        source.url = base.appendingPathComponent("list").absoluteString
        source.header = #"{"Cookie":"explicit_fixture=yes"}"#
        source.enabledCookieJar = false
        _ = try await LegadoRSSScraper.scrape(source: source, requestSession: session)
        #expect((HTTPCookieStorage.shared.cookies ?? []).allSatisfy { $0.name != cookieName })
        source.enabledCookieJar = true
        _ = try await LegadoRSSScraper.scrape(source: source, requestSession: session)
        #expect((HTTPCookieStorage.shared.cookies ?? []).contains { $0.name == cookieName })
        #expect(server.requests.count == 2)
        #expect(server.requests.allSatisfy { $0.headers["cookie"]?.contains("explicit_fixture=yes") == true })
    }

    @Test("JS URL-options响应保留真实状态与headers")
    func optionResponseMetadata() async throws {
        let host = hostName()
        let session = RSSPageFixtureProtocol.makeSession()
        RSSPageFixtureProtocol.serve(host: host, sequences: [
            "/list": [.init(body: html)],
            "/api": [.init(body: Data("body".utf8), status: 418, headers: ["X-Fixture": "yes"])]
        ])
        defer { session.invalidateAndCancel(); RSSPageFixtureProtocol.remove(host: host) }
        var source = rules(host: host)
        source.ruleTitle = """
        @js: var response = java.ajaxAll(['https://\(host)/api,{"charset":"utf-8"}'])[0];
        response.code() + '|' + response.headers().get('X-Fixture') + '|' + response.body()
        """
        let items = try await LegadoRSSScraper.scrape(source: source, requestSession: session)
        #expect(items.first?.title == "418|yes|body")
        #expect(RSSPageFixtureProtocol.requests(host: host).count == 2)
    }

    @Test("无列表规则的Legado Feed仍执行jsLib/headers/loginCheck并支持304")
    func rulelessFeedRuntime() async throws {
        let host = hostName()
        let session = RSSPageFixtureProtocol.makeSession()
        let xml = #"<?xml version="1.0" encoding="GBK"?><rss version="2.0"><channel><title>新闻</title><item><guid>one</guid><title>第一篇</title><link>https://fixture.invalid/one</link></item></channel></rss>"#
        RSSPageFixtureProtocol.serve(host: host, sequences: [
            "/feed": [.init(body: Data("login".utf8), status: 403), .init(body: Data(), status: 304)],
            "/authorized": [.init(body: Data("ignored".utf8), headers: ["ETag": "fixture-tag"])]
        ])
        defer { session.invalidateAndCancel(); RSSPageFixtureProtocol.remove(host: host) }
        var source = RSSSource(name: "XML fixture", url: "https://\(host)/feed")
        source.importedFromLegado = true
        source.jsLib = "function fixtureToken(){return 'fixture'};"
        source.header = "@js: JSON.stringify({'X-Fixture': fixtureToken()})"
        // 正文变换返回解码后的XML；声明中的GBK不能让UTF-8重新编码的数据乱码。
        let literal = String(decoding: try JSONEncoder().encode(xml), as: UTF8.self)
        source.loginCheckJs = "if(result.code()===403) java.connect('https://\(host)/authorized');"
        let options = try JSONSerialization.data(withJSONObject: ["bodyJs": literal], options: [.sortedKeys])
        source.url += "," + String(decoding: options, as: UTF8.self)
        let fetcher = RSSFetcher(session: session)
        await fetcher.fetchItems(from: source)
        #expect(fetcher.error == nil)
        #expect(fetcher.items.first?.title == "第一篇")
        guard case .updated(_, let metadata, _)? = fetcher.response else { Issue.record("没有Feed响应"); return }
        #expect(metadata.etag == "fixture-tag")
        await fetcher.fetchItems(from: source, metadata: metadata)
        guard case .notModified? = fetcher.response else { Issue.record("304不能重跑bodyJs"); return }
        let requests = RSSPageFixtureProtocol.requests(host: host)
        #expect(requests.count == 3)
        #expect(requests.allSatisfy { $0.value(forHTTPHeaderField: "X-Fixture") == "fixture" })
        #expect(requests.last?.value(forHTTPHeaderField: "If-None-Match") == "fixture-tag")
    }

    @Test("取消活动请求后，尚未执行的同源请求重绑一次且不串文章变量")
    func cancellationAndQueuedArticle() async throws {
      for _ in 0..<100 {
        try await withStore { store, _ in
            let host = hostName()
            let session = RSSPageFixtureProtocol.makeSession()
            let (events, continuation) = AsyncStream<URLRequest>.makeStream()
            RSSPageFixtureProtocol.serve(host: host, sequences: [
                "/a": [.init(body: html, held: true)], "/b": [.init(body: html)]
            ], events: continuation)
            var source = rules(host: host)
            source.ruleContent = "@js: rssArticle.title + '|' + java.get('marker')"
            store.addSource(source)
            let snapshot = source
            let runtime = try await RSSRuntime.make(source: source, owner: store, requestSession: session)
            let first = Task { try await LegadoRSSScraper.fetchArticleContent(source: snapshot, articleLink: "https://\(host)/a", owner: store,
                variables: ["marker": "A"], articleTitle: "A", requestSession: session) }
            var second: Task<String?, Error>?
            defer {
                first.cancel(); second?.cancel(); session.invalidateAndCancel()
                continuation.finish(); RSSPageFixtureProtocol.remove(host: host)
            }
            var iterator = events.makeAsyncIterator()
            #expect(await iterator.next()?.url?.path == "/a")
            second = Task { try await LegadoRSSScraper.fetchArticleContent(source: snapshot, articleLink: "https://\(host)/b", owner: store,
                variables: ["marker": "B"], articleTitle: "B", requestSession: session) }
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: .seconds(3))
            while runtime.session.queuedCallers == 0 && clock.now < deadline && !Task.isCancelled { await Task.yield() }
            try #require(runtime.session.queuedCallers == 1)
            first.cancel()
            do { _ = try await first.value; Issue.record("活动请求未取消") } catch is CancellationError { }
            let pending = try #require(second)
            #expect(try await pending.value == "B|B")
            #expect(RSSPageFixtureProtocol.requests(host: host).map { $0.url?.path } == ["/a", "/b"])
        }
      }
    }

    @Test("取消发生在java.ajax内时，晚到脚本不能写cache/Cookie或登录头")
    func cancelledScriptCannotWriteSideEffects() async throws {
        try await withStore { store, _ in
            let host = hostName()
            let session = RSSPageFixtureProtocol.makeSession()
            let (events, continuation) = AsyncStream<URLRequest>.makeStream()
            let cookie = "late_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
            RSSPageFixtureProtocol.serve(host: host, sequences: [
                "/list": [.init(body: html)], "/wait": [.init(body: Data(), held: true)]
            ], events: continuation)
            var source = rules(host: host)
            source.ruleTitle = "@js:java.ajax('https://\(host)/wait'); cache.put('late','bad'); cookie.set('https://\(host)','\(cookie)=bad'); source.putLoginHeader('bad'); 'Late'"
            store.addSource(source)
            let key = RSSRuntime.authenticationKey(for: source)
            let snapshot = source
            let task = Task { try await LegadoRSSScraper.scrape(source: snapshot, owner: store, requestSession: session) }
            defer {
                task.cancel(); session.invalidateAndCancel(); continuation.finish(); RSSPageFixtureProtocol.remove(host: host)
                CookieStore.shared.remove(url: "https://\(host)", key: cookie)
                LoginManager.shared.clearLogin(sourceUrl: key)
            }
            var iterator = events.makeAsyncIterator()
            #expect(await iterator.next()?.url?.path == "/list")
            #expect(await iterator.next()?.url?.path == "/wait")
            source.ruleTitle = "a@text"
            store.updateSource(source)
            do { _ = try await task.value; Issue.record("脚本请求未取消") } catch is CancellationError { }
            let current = try await RSSRuntime.make(source: source, owner: store, requestSession: session)
            let cached = try await current.run { host in
                await host.run { $0.evaluateSourceScript("var value=cache.get('late')||'';cache.delete('late');value") }
            }
            #expect(cached == "")
            #expect(CookieStore.shared.getKey(url: "https://\(host)", key: cookie).isEmpty)
            #expect(LoginManager.shared.getLoginHeader(sourceUrl: key) == nil)
        }
    }

    @Test("文章字段按Android顺序设置，描述规则能填补初始空标题")
    func articleContextAssignmentOrder() async throws {
        let host = hostName()
        let session = RSSPageFixtureProtocol.makeSession()
        RSSPageFixtureProtocol.serve(host: host, contentType: "text/html", body: html)
        defer { session.invalidateAndCancel(); RSSPageFixtureProtocol.remove(host: host) }
        var source = rules(host: host)
        source.contentType = .video
        source.ruleTitle = "@js:java.put('initial',rssArticle.origin+'|'+rssArticle.sort+'|'+rssArticle.type);''"
        source.ruleDescription = "@js:rssArticle.title='Filled';java.get('initial')"
        let items = try await LegadoRSSScraper.scrape(source: source, entry: .init(name: "Category", url: source.url), requestSession: session)
        #expect(items.first?.title == "Filled")
        #expect(items.first?.contentHTML == "||0")
    }

    @Test("不可读的未来运行状态阻止脚本执行且不覆盖文件")
    func futureRuntimeStateStopsExecution() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("rss-future-\(UUID().uuidString)")
        defer { do { try FileManager.default.removeItem(at: directory) } catch { Issue.record(error) } }
        let original = RSSStore(storageDirectory: directory)
        var source = rules(host: hostName())
        source.jsLib = "java.put('must-not-run','value')"
        original.addSource(source)
        try await original.flushPersistence()
        let file = directory.appendingPathComponent("rss_runtime_variables.json")
        let future = Data(#"{"schemaVersion":99,"values":{},"options":{}}"#.utf8)
        try future.write(to: file)
        let restored = RSSStore(storageDirectory: directory)
        do { _ = try await RSSRuntime.make(source: source, owner: restored); Issue.record("未知状态不应进入执行器") }
        catch ScraperError.runtimeStateUnavailable { }
        #expect(try Data(contentsOf: file) == future)
        #expect(restored.variables(for: source.id).isEmpty)
    }

    @Test("jsLib超过执行预算必须失败，不执行网络或提交部分变量")
    func scriptTimeoutCannotBecomeSuccess() async throws {
      for kind in ["jsLib", "header"] {
        try await withStore { store, _ in
            let host = hostName()
            let session = RSSPageFixtureProtocol.makeSession()
            RSSPageFixtureProtocol.serve(host: host, contentType: "text/html", body: html)
            defer { session.invalidateAndCancel(); RSSPageFixtureProtocol.remove(host: host) }
            var source = rules(host: host)
            // 有限CPU循环模拟失控脚本；测试预算缩短，不依赖sleep等待状态。
            let loop = "java.put('before','partial'); var until=Date.now()+250; while(Date.now()<until){}; java.put('after','late');"
            if kind == "jsLib" { source.jsLib = loop }
            else { source.header = "@js:" + loop + " JSON.stringify({'X-Late':'bad'})" }
            store.addSource(source)
            try await store.flushPersistence()
            let writes = store.writeCounts
            let state = RSSRuntimeState(try store.runtimeSnapshot(for: source), authenticationKey: RSSRuntime.authenticationKey(for: source))
            let overrides = SourceRuntimeOverrides(identity: UUID().uuidString, authenticationKey: RSSRuntime.authenticationKey(for: source),
                propertiesJSON: Data("{}".utf8), state: state, scriptTimeout: 0.03)
            let shared = BookSourceSession(source: RSSRuntime.scriptSource(source), requestSession: session, runtimeOverrides: overrides)
            let runtime = RSSRuntime(source: source, session: shared, state: state, owner: store,
                ticket: store.requestTicket(for: source.id), requestSession: session)
            let url = source.url
            do {
                _ = try await runtime.run { host in try await host.fetchRulePage(ruleURL: url, isPrimaryRequest: true) }
                Issue.record("超时不能成为成功响应")
            } catch ScraperError.executionTimedOut { }
            #expect(!state.isActive && state.didTimeOut)
            #expect(store.variables(for: source.id).isEmpty)
            #expect(RSSPageFixtureProtocol.requests(host: host).isEmpty)
            try await store.flushPersistence()
            #expect(store.writeCounts == writes)
        }
      }
    }

    @Test("外部变量修改撤销旧票据，新会话读取owner的新值")
    func ownerVariableChangeInvalidatesSession() async throws {
        try await withStore { store, _ in
            let source = rules(host: hostName())
            store.addSource(source)
            store.setVariables(["filter": "A"], for: source.id)
            let first = try await RSSRuntime.make(source: source, owner: store)
            let oldTicket = try #require(store.requestTicket(for: source.id))
            let a = try await first.run { host in await host.run { $0.evaluateSourceScript("java.get('filter')") } }
            #expect(a == "A")
            store.setVariables(["filter": "B"], for: source.id)
            #expect(!first.state.isCurrent && !store.accepts(oldTicket))
            let second = try await RSSRuntime.make(source: source, owner: store)
            let b = try await second.run { host in await host.run { $0.evaluateSourceScript("java.get('filter')") } }
            #expect(b == "B")
        }
    }

    private var html: Data { Data(#"<div class="item"><a href="/one">One</a></div>"#.utf8) }
    private func hostName() -> String { "rss-runtime-\(UUID().uuidString.lowercased()).invalid" }
    private func rules(host: String) -> RSSSource {
        var source = RSSSource(name: "Runtime fixture", url: "https://\(host)/list")
        source.ruleArticles = "class.item"; source.ruleTitle = "a@text"; source.ruleLink = "a@href"
        return source
    }
    private func withStore(_ body: @MainActor (RSSStore, URL) async throws -> Void) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("rss-runtime-\(UUID().uuidString)")
        let store = RSSStore(storageDirectory: directory)
        var failure: Error?
        do { try await body(store, directory) } catch { failure = error }
        do { try await store.flushPersistence() } catch { Issue.record(error) }
        do { try FileManager.default.removeItem(at: directory) } catch { Issue.record("测试目录清理失败") }
        if let failure { throw failure }
    }
}
