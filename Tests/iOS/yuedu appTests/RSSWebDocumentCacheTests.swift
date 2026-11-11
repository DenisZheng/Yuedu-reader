import Foundation
import Testing
@testable import yuedu_app

@Suite("RSS cacheFirst first document", .serialized)
struct RSSWebDocumentCacheTests {
    private let directory = URL.temporaryDirectory
    private func load(_ url: URL, _ source: RSSSource, header: String? = nil) async throws -> String {
        var request = URLRequest(url: url)
        request.setValue(header, forHTTPHeaderField: "X-Account")
        return String(decoding: try await RSSOpenTarget.loadDocument(request, source: source).data, as: UTF8.self)
    }

    @Test("开启时第二次不发请求且不重放Set-Cookie；关闭时每次请求")
    func hitAvoidsNetwork() async throws {
        let name = "cachefirst" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let server = try VideoStillFixtureServer(directory: directory, routes: [
            "/page": .init(body: Data("<p>cached</p>".utf8), type: "text/html", headers: ["Set-Cookie": name + "=one; Path=/", "Cache-Control": "max-age=60"])
        ])
        let base = try await server.start()
        defer { server.stop(); CookieStore.shared.remove(url: base.absoluteString, key: name) }
        let url = base.appendingPathComponent("page")
        var source = RSSSource(name: "Cache", url: base.absoluteString)
        source.cacheFirst = true
        #expect(try await load(url, source).contains("cached"))
        CookieStore.shared.remove(url: base.absoluteString, key: name)
        #expect(try await load(url, source).contains("cached"))
        #expect(server.requests.filter { $0.path == "/page" }.count == 1)
        #expect(!CookieStore.shared.requestHeader(for: url).contains(name), "缓存命中不能复活已删除Cookie")
        source.cacheFirst = false
        _ = try await load(url, source)
        _ = try await load(url, source)
        #expect(server.requests.filter { $0.path == "/page" }.count == 3)
    }

    @Test("连续HTTP404不能被缓存：重试发出新请求，服务器恢复200后立即成功", arguments: [false, true])
    func notFoundThenRecovery(cacheFirst: Bool) async throws {
        final class Sequence: @unchecked Sendable {
            let lock = NSLock()
            var count = 0
            func next() -> Int { lock.withLock { count += 1; return count } }
        }
        let sequence = Sequence()
        let server = try VideoStillFixtureServer(directory: directory)
        server.route { request in
            guard request.path == "/recover" else { return nil }
            let attempt = sequence.next()
            return .init(body: Data((attempt < 3 ? "Not Found" : "<p>recovered</p>").utf8), type: "text/html",
                         status: attempt < 3 ? "404 Not Found" : "200 OK",
                         headers: ["Cache-Control": "public, max-age=3600"])
        }
        let base = try await server.start()
        defer { server.stop() }
        let url = base.appendingPathComponent("recover")
        var source = RSSSource(name: "404 retry", url: base.absoluteString)
        source.cacheFirst = cacheFirst
        for _ in 0..<2 {
            do {
                _ = try await load(url, source)
                Issue.record("404不应变为加载成功")
            } catch {
                guard case ScraperError.httpStatus(404) = error else { throw error }
            }
        }
        #expect(server.requests.filter { $0.path == "/recover" }.count == 2, "每次404重试必须重新访问服务器")
        #expect(try await load(url, source).contains("recovered"))
        #expect(server.requests.filter { $0.path == "/recover" }.count == 3)
        #expect(try await load(url, source).contains("recovered"))
        #expect(server.requests.filter { $0.path == "/recover" }.count == (cacheFirst ? 3 : 4), "只有成功页且开启cacheFirst才命中缓存")
    }

    @Test("账号头不同不串页面；no-store与错误响应不缓存")
    func credentialAndStorageBoundaries() async throws {
        let server = try VideoStillFixtureServer(directory: directory, routes: [
            "/account": .init(body: Data("<p>page</p>".utf8), type: "text/html", headers: ["Cache-Control": "max-age=60"]),
            "/private": .init(body: Data("<p>private</p>".utf8), type: "text/html", headers: ["Cache-Control": "no-store"]),
            "/denied": .init(body: Data(), status: "403 Forbidden", headers: ["Cache-Control": "max-age=60"])
        ])
        let base = try await server.start()
        defer { server.stop() }
        var source = RSSSource(name: "Boundary", url: base.absoluteString)
        source.cacheFirst = true
        _ = try await load(base.appendingPathComponent("account"), source, header: "one")
        _ = try await load(base.appendingPathComponent("account"), source, header: "two")
        #expect(server.requests.filter { $0.path == "/account" }.count == 2)
        _ = try await load(base.appendingPathComponent("private"), source)
        _ = try await load(base.appendingPathComponent("private"), source)
        #expect(server.requests.filter { $0.path == "/private" }.count == 2)
        for _ in 0..<2 {
            do { _ = try await load(base.appendingPathComponent("denied"), source); Issue.record("403不应成功") }
            catch { #expect(error is ScraperError) }
        }
        #expect(server.requests.filter { $0.path == "/denied" }.count == 2)
    }
}
