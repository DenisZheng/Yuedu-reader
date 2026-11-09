import Foundation
import Testing
@testable import yuedu_app

@Suite("RSS cookie authorization", .serialized)
struct RSSCookieAuthorizationTests {
    @Test("收到旧响应前凭据已改变：自动CookieJar不能越过源授权写入旧登录Cookie")
    func staleResponseCannotWriteCookie() async throws {
        let name = "rss_cookie_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let key = "rss.authorization." + UUID().uuidString
        let server = try VideoStillFixtureServer(directory: .temporaryDirectory, routes: [
            "/late": .init(body: Data("Old response".utf8), headers: ["Set-Cookie": "\(name)=obsolete; Path=/"])
        ])
        let base = try await server.start()
        let state = RSSRuntimeState(.init(), authenticationKey: key)
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = .shared
        config.urlCredentialStorage = nil
        let session = URLSession(configuration: config)
        defer {
            server.stop(); session.invalidateAndCancel()
            LoginManager.shared.removeLoginHeader(sourceUrl: key)
            for cookie in HTTPCookieStorage.shared.cookies ?? [] where cookie.name == name { HTTPCookieStorage.shared.deleteCookie(cookie) }
        }
        server.observeRequests { _ in LoginManager.shared.storeLoginHeader(sourceUrl: key, raw: "new-fixture") }
        let executor = SourceRequestExecutor(session: session, rate: "", rateKey: key, cookieJarEnabled: true, runtimeState: state)
        do {
            _ = try await executor.data(for: URLRequest(url: base.appendingPathComponent("late")))
            Issue.record("旧响应未被授权边界拒绝")
        } catch is CancellationError { }
        #expect((HTTPCookieStorage.shared.cookies ?? []).allSatisfy { $0.name != name })
    }

    @Test("HTTP响应不能为无关域种Cookie，不能把原生单Cookie API当响应域校验")
    func responseCannotPoisonOtherDomain() async throws {
        let name = "rsspoison" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let domain = "rss-other-" + UUID().uuidString.lowercased() + ".invalid"
        let server = try VideoStillFixtureServer(directory: .temporaryDirectory, routes: [
            "/poison": .init(body: Data("OK".utf8), headers: ["Set-Cookie": "\(name)=wrong; Domain=\(domain); Path=/"])
        ])
        let base = try await server.start()
        let session = URLSession(configuration: .ephemeral)
        defer {
            server.stop(); session.invalidateAndCancel()
            for cookie in HTTPCookieStorage.shared.cookies ?? [] where cookie.name == name { HTTPCookieStorage.shared.deleteCookie(cookie) }
        }
        let executor = SourceRequestExecutor(session: session, rate: "", rateKey: UUID().uuidString, cookieJarEnabled: true,
                                             runtimeState: RSSRuntimeState(.init()))
        _ = try await executor.data(for: URLRequest(url: base.appendingPathComponent("poison")))
        #expect((HTTPCookieStorage.shared.cookies ?? []).allSatisfy { $0.name != name })
    }

    @Test("过期Set-Cookie不能从旧扁平快照复活")
    func expiredCookieRemovesLegacy() async throws {
        let host = "rss-expired-" + UUID().uuidString.lowercased() + ".invalid"
        let url = "https://" + host + "/"
        defer { CookieStore.shared.remove(url: url, key: "fixture") }
        try await SourceScriptThread.run {
            CookieStore.shared.set(url: url, cookie: "fixture=old")
            let expired = try #require(HTTPCookie(properties: [.name: "fixture", .value: "", .domain: host, .path: "/", .expires: Date(timeIntervalSince1970: 1)]))
            try CookieStore.shared.synchronizeWebCookies([expired], removed: [])
        }
        #expect(CookieStore.shared.getKey(url: url, key: "fixture").isEmpty)
    }

    @Test("有属性的Cookie退休旧扁平值，丢失会话Cookie后不能回退为无Secure/过期属性的旧认证")
    func structuredCookieRetiresLegacy() async throws {
        let host = "rss-structured-" + UUID().uuidString.lowercased() + ".invalid"
        let url = "https://" + host + "/"
        defer { CookieStore.shared.remove(url: url, key: "fixture") }
        let structured = try #require(HTTPCookie(properties: [.name: "fixture", .value: "new", .domain: host, .path: "/", .secure: "TRUE"]))
        try await SourceScriptThread.run {
            CookieStore.shared.set(url: url, cookie: "fixture=old")
            try CookieStore.shared.synchronizeWebCookies([structured], removed: [])
        }
        #expect(CookieStore.shared.requestHeader(for: URL(string: url)!).contains("fixture=new"))
        #expect(!CookieStore.shared.requestHeader(for: URL(string: "http://" + host)!).contains("fixture="))
        HTTPCookieStorage.shared.deleteCookie(structured)
        #expect(CookieStore.shared.getKey(url: url, key: "fixture").isEmpty)
    }

    @Test("合法302的Cookie先按域/path管理，再发到同域目标；关闭自动Jar不保存响应")
    func redirectCookieContract() async throws {
        for enabled in [false, true] {
            let name = "rss_redirect_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
            let server = try VideoStillFixtureServer(directory: .temporaryDirectory, routes: [
                "/start": .init(body: Data(), status: "302 Found", headers: ["Location": "/private/final", "Set-Cookie": "\(name)=valid; Path=/private"]),
                "/private/final": .init(body: Data("Final".utf8))
            ])
            let base = try await server.start()
            let config = URLSessionConfiguration.ephemeral
            config.httpCookieStorage = .shared; config.urlCredentialStorage = nil
            let session = URLSession(configuration: config)
            defer {
                server.stop(); session.invalidateAndCancel()
                for cookie in HTTPCookieStorage.shared.cookies ?? [] where cookie.name == name { HTTPCookieStorage.shared.deleteCookie(cookie) }
            }
            let executor = SourceRequestExecutor(session: session, rate: "", rateKey: UUID().uuidString, cookieJarEnabled: enabled,
                                                 runtimeState: RSSRuntimeState(.init()))
            _ = try await executor.data(for: URLRequest(url: base.appendingPathComponent("start")))
            let final = try #require(server.requests.last)
            #expect(final.path == "/private/final")
            #expect((final.headers["cookie"]?.contains(name + "=valid") == true) == enabled)
            #expect(!CookieStore.shared.requestHeader(for: base.appendingPathComponent("public")).contains(name + "="))
        }
    }
}
