import Foundation
import Testing
import CryptoKit
@testable import yuedu_app

@Suite("S8 pre-wire request boundary", .serialized)
struct S8RequestBoundaryTests {
    @Test("对照证明生产task delegate会覆盖Session层重定向拒绝")
    func sessionRedirectDelegateIsNotAnEnforcementBoundary() async throws {
        let target = try VideoStillFixtureServer(directory: .temporaryDirectory, routes: [
            "/target": .init(body: Data("Target".utf8))
        ])
        let targetURL = try await target.start().appendingPathComponent("target")
        let origin = try VideoStillFixtureServer(directory: .temporaryDirectory, routes: [
            "/start": .init(body: Data(), status: "302 Found", headers: ["Location": targetURL.absoluteString])
        ])
        let base = try await origin.start()
        defer { origin.stop(); target.stop() }
        let spy = RedirectSpy()
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil; config.urlCredentialStorage = nil
        let session = URLSession(configuration: config, delegate: spy, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let executor = SourceRequestExecutor(session: session, rate: "", rateKey: UUID().uuidString,
            cookieJarEnabled: false, runtimeState: RSSRuntimeState(.init()))
        let (_, response) = try await executor.data(for: URLRequest(url: base.appendingPathComponent("start")))
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        #expect(origin.requests.count == 1 && target.requests.count == 1)
        #expect(spy.redirectCount == 0, "Session回调未被调用不能证明没有跟随跳转")
    }

    @Test("生产task delegate覆盖Session跳转拦截时，未准入的目标仍不收到请求")
    func redirectRejectedBeforeNetwork() async throws {
        let destination = try VideoStillFixtureServer(directory: .temporaryDirectory, routes: [
            "/unreviewed": .init(body: Data("Unreviewed".utf8))
        ])
        let target = try await destination.start().appendingPathComponent("unreviewed")
        let origin = try VideoStillFixtureServer(directory: .temporaryDirectory, routes: [
            "/reviewed": .init(body: Data(), status: "302 Found", headers: ["Location": target.absoluteString])
        ])
        let base = try await origin.start()
        defer { origin.stop(); destination.stop() }
        let url = base.appendingPathComponent("reviewed")
        let boundary = try S8RequestBoundary(urls: [url], maximumRequests: 1)
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil; config.urlCredentialStorage = nil
        boundary.configure(config)
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel(); boundary.close() }
        let executor = SourceRequestExecutor(session: session, rate: "", rateKey: UUID().uuidString,
            cookieJarEnabled: false, runtimeState: RSSRuntimeState(.init()))
        do {
            _ = try await executor.data(for: URLRequest(url: url))
            Issue.record("未预审重定向没有在发出前失败")
        } catch { #expect((error as NSError).domain == "S8RequestBoundary") }
        #expect(origin.requests.count == 1)
        #expect(destination.requests.isEmpty)
        #expect(boundary.counts.approved == 1 && boundary.counts.rejected >= 1)
    }

    @Test("只允许预审哈希对应的确切跳转URL，保留系统HTTP和生产重定向处理")
    func reviewedRedirectUsesNativeTransport() async throws {
        let server = try VideoStillFixtureServer(directory: .temporaryDirectory, routes: [
            "/start": .init(body: Data(), status: "301 Moved Permanently", headers: ["Location": "/canonical"]),
            "/canonical": .init(body: Data("Canonical".utf8))
        ])
        let base = try await server.start()
        defer { server.stop() }
        let target = base.appendingPathComponent("canonical")
        let hash = SHA256.hash(data: Data(target.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined()
        let url = base.appendingPathComponent("start")
        let boundary = try S8RequestBoundary(urls: [url], maximumRequests: 3, approvedURLHashes: [hash])
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil; config.urlCredentialStorage = nil
        boundary.configure(config)
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel(); boundary.close() }
        let executor = SourceRequestExecutor(session: session, rate: "", rateKey: UUID().uuidString,
            cookieJarEnabled: false, runtimeState: RSSRuntimeState(.init()))
        let (_, response) = try await executor.data(for: URLRequest(url: url))
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        #expect(server.requests.map(\.path) == ["/start", "/canonical"])
        #expect(boundary.counts.approved <= 3 && boundary.counts.rejected == 0)
    }

    @Test("只有媒体验收显式准入HEAD，仍受确切URL、方法和次数约束")
    func mediaHeadIsExplicitAndBounded() async throws {
        let server = try VideoStillFixtureServer(directory: .temporaryDirectory, routes: [
            "/media": .init(body: Data([1, 2, 3]), type: "audio/mpeg")
        ])
        let base = try await server.start()
        defer { server.stop() }
        let url = base.appendingPathComponent("media")
        let boundary = try S8RequestBoundary(urls: [url], maximumRequests: 2, allowsHead: true)
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil; config.urlCredentialStorage = nil; config.urlCache = nil
        boundary.configure(config)
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel(); boundary.close() }
        var head = URLRequest(url: url); head.httpMethod = "HEAD"
        let (body, response) = try await session.data(for: head)
        #expect(body.isEmpty && (response as? HTTPURLResponse)?.statusCode == 200)
        var post = URLRequest(url: url); post.httpMethod = "POST"
        do { _ = try await session.data(for: post); Issue.record("准入HEAD不能放行POST") }
        catch { #expect((error as NSError).domain == "S8RequestBoundary") }
        _ = try await session.data(from: url)
        do { _ = try await session.data(for: head); Issue.record("HEAD不能越过总请求预算") }
        catch { #expect((error as NSError).domain == "S8RequestBoundary") }
        #expect(server.requests.map(\.method) == ["HEAD", "GET"])
    }

    @Test("只准入GET、无凭据、有限次数；Session不转发被拒绝的请求")
    func methodsCredentialsAndBudget() async throws {
        let server = try VideoStillFixtureServer(directory: .temporaryDirectory, routes: [
            "/reviewed": .init(body: Data("Reviewed".utf8))
        ])
        let base = try await server.start()
        defer { server.stop() }
        let url = base.appendingPathComponent("reviewed")
        let boundary = try S8RequestBoundary(urls: [url], maximumRequests: 1)
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil; config.urlCredentialStorage = nil; config.urlCache = nil
        boundary.configure(config)
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel(); boundary.close() }
        var post = URLRequest(url: url); post.httpMethod = "POST"
        var cookie = URLRequest(url: url); cookie.setValue("fixture=private", forHTTPHeaderField: "Cookie")
        var auth = URLRequest(url: url); auth.setValue("Bearer fixture", forHTTPHeaderField: "Authorization")
        var apiKey = URLRequest(url: url); apiKey.setValue("fixture-api-key", forHTTPHeaderField: "X-API-Key")
        var privateHeader = URLRequest(url: url); privateHeader.setValue("fixture-private", forHTTPHeaderField: "X-Private-Fixture")
        for request in [post, cookie, auth, apiKey, privateHeader, URLRequest(url: base.appendingPathComponent("not-reviewed"))] {
            do { _ = try await session.data(for: request); Issue.record("未预审请求被允许") }
            catch { #expect((error as NSError).domain == "S8RequestBoundary") }
        }
        #expect(server.requests.isEmpty)
        let (_, response) = try await session.data(from: url)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        do { _ = try await session.data(from: url); Issue.record("超过请求预算仍可继续") }
        catch { #expect((error as NSError).domain == "S8RequestBoundary") }
        #expect(server.requests.count == 1)
        #expect(boundary.counts.approved == 1 && boundary.counts.rejected >= 7)
    }

    private final class RedirectSpy: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        var redirectCount: Int { lock.withLock { count } }
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            lock.withLock { count += 1 }
            completionHandler(nil)
        }
    }
}
