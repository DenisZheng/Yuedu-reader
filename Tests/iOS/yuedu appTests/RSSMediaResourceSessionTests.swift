import Foundation
import Testing
@testable import yuedu_app

@Suite("RSS player resource security and bounded HTTP", .serialized)
struct RSSMediaResourceSessionTests {
    private var fixtures: URL { VideoStillFixtures.directory() }

    @Test("实际播放器端点正确支持单字节、后缀、开放Range和HEAD；相邻小Range合并上游")
    func rangeAndHead() async throws {
        let server = try VideoStillFixtureServer(directory: fixtures)
        let base = try await server.start()
        defer { server.stop() }
        let source = RSSSource(name: "Range", url: base.absoluteString)
        let prepared = try await RSSMediaRequestService.prepare(base.appendingPathComponent("video-still-landscape.mp4").absoluteString,
            source: source, base: base, context: nil, owner: nil, trustedRuleURL: false)
        let (stream, resources) = try await RSSMediaRequestService.stream(prepared)
        defer { resources.stop() }
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: stream.url)
        request.httpMethod = "HEAD"
        let (head, headResponse) = try await session.data(for: request)
        #expect(head.isEmpty)
        let count = try #require(Int((headResponse as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Length") ?? ""))
        #expect(count > 1_024)
        request.httpMethod = "GET"
        for (range, size) in [("bytes=0-0", 1), ("bytes=1-2", 2), ("bytes=-8", 8), ("bytes=\(count - 8)-", 8)] {
            request.setValue(range, forHTTPHeaderField: "Range")
            let (data, response) = try await session.data(for: request)
            #expect((response as? HTTPURLResponse)?.statusCode == 206)
            #expect(data.count == size)
        }
        #expect(server.requests.count <= 3, "HEAD、前块和尾部，不能将AVPlayer每个小Range映射为上游请求")
        request.setValue("bytes=\(count)-", forHTTPHeaderField: "Range")
        let (_, invalid) = try await session.data(for: request)
        #expect((invalid as? HTTPURLResponse)?.statusCode == 416)
        #expect((invalid as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Range") == "bytes */\(count)")
    }

    @Test("清单与实际分片按路径读取Cookie且不将源私有头重定向到另一个origin")
    func manifestCredentialScope() async throws {
        let target = try VideoStillFixtureServer(directory: fixtures)
        let targetBase = try await target.start()
        defer { target.stop() }
        let playlist = "#EXTM3U\n#EXT-X-VERSION:7\n#EXT-X-TARGETDURATION:4\n#EXT-X-MAP:URI=\"/private/init\"\n#EXTINF:4,\n/public/segment\n#EXT-X-ENDLIST\n"
        let server = try VideoStillFixtureServer(directory: fixtures, routes: [
            "/stream.m3u8": .init(body: Data(playlist.utf8), type: "application/vnd.apple.mpegurl", requiredHeaders: ["x-rss-private": "fixture-only"]),
            "/private/init": .init(body: Data([1, 2, 3]), requiredHeaders: ["cookie": "rss_media_path=fixture-only"]),
            "/public/segment": .init(body: Data([4, 5, 6])),
            "/redirect": .init(body: Data(), status: "302 Found", headers: ["Location": targetBase.appendingPathComponent("video-still-landscape.mp4").absoluteString])
        ])
        let base = try await server.start()
        defer { server.stop() }
        let cookie = try #require(HTTPCookie(properties: [.domain: "127.0.0.1", .path: "/private", .name: "rss_media_path", .value: "fixture-only"]))
        try CookieStore.shared.synchronizeWebCookies([cookie], removed: [])
        defer { do { try CookieStore.shared.synchronizeWebCookies([], removed: [cookie]) } catch { Issue.record(error) } }
        var source = RSSSource(name: "Credential", url: base.absoluteString)
        source.header = #"{"X-RSS-Private":"fixture-only"}"#
        let prepared = try await RSSMediaRequestService.prepare(base.appendingPathComponent("stream.m3u8").absoluteString,
            source: source, base: base, context: nil, owner: nil, trustedRuleURL: false)
        let (stream, resources) = try await RSSMediaRequestService.stream(prepared)
        defer { resources.stop() }
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let (bytes, response) = try await session.data(from: stream.url)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        let rewritten = try #require(String(data: bytes, encoding: .utf8))
        let uris = try NSRegularExpression(pattern: "http://127\\.0\\.0\\.1:[0-9]+/[^\\\"\\s]+")
        let urls = uris.matches(in: rewritten, range: NSRange(rewritten.startIndex..., in: rewritten)).compactMap { match -> URL? in
            guard let range = Range(match.range, in: rewritten) else { return nil }
            return URL(string: String(rewritten[range]))
        }
        #expect(urls.count == 2)
        for url in urls {
            let (_, response) = try await session.data(from: url)
            #expect((response as? HTTPURLResponse)?.statusCode == 200)
        }
        #expect(server.requests.first { $0.path == "/private/init" }?.headers["cookie"] == "rss_media_path=fixture-only")
        #expect(server.requests.first { $0.path == "/public/segment" }?.headers["cookie"] == nil)
        #expect(!rewritten.contains(base.absoluteString), "清单不能暴露上游URL或私有凭据")
        let redirected = try await RSSMediaRequestService.prepare(base.appendingPathComponent("redirect").absoluteString,
            source: source, base: base, context: nil, owner: nil, trustedRuleURL: false)
        let (redirectStream, redirectResources) = try await RSSMediaRequestService.stream(redirected)
        defer { redirectResources.stop() }
        let (_, denied) = try await session.data(from: redirectStream.url)
        #expect((denied as? HTTPURLResponse)?.statusCode == 502)
        #expect(target.requests.isEmpty, "不向未授权loopback origin发送任何源私有头")
    }

    @Test("未知capability、跨origin网页与媒体结束后请求都不能获得任意URL代理")
    func capabilityAndClose() async throws {
        let server = try VideoStillFixtureServer(directory: fixtures)
        let base = try await server.start()
        defer { server.stop() }
        let source = RSSSource(name: "Capability", url: base.absoluteString)
        let prepared = try await RSSMediaRequestService.prepare(base.appendingPathComponent("video-still-landscape.mp4").absoluteString,
            source: source, base: base, context: nil, owner: nil, trustedRuleURL: false)
        let (stream, resources) = try await RSSMediaRequestService.stream(prepared)
        defer { resources.stop() }
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        var unknown = URLComponents(url: stream.url, resolvingAgainstBaseURL: false)!
        unknown.path = "/https://private.invalid/path"; unknown.query = nil
        let (_, denied) = try await session.data(from: unknown.url!)
        #expect((denied as? HTTPURLResponse)?.statusCode == 502)
        #expect(server.requests.isEmpty)
        var webpage = URLRequest(url: stream.url)
        webpage.setValue("https://external.invalid", forHTTPHeaderField: "Origin")
        do { _ = try await session.data(for: webpage); Issue.record("跨源网页可读取本地媒体") }
        catch { #expect(error is URLError) }
        #expect(server.requests.isEmpty)
        stream.closeResource()
        do { _ = try await session.data(from: stream.url); Issue.record("关闭播放器后端点仍可读取") }
        catch { #expect(error is URLError) }
        #expect(server.requests.isEmpty)
    }
}
