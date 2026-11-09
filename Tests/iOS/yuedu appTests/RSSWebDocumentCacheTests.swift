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
