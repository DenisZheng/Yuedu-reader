import Foundation
import os

/// 仅接管显式登记的合成host，供RSS的URLSession固定响应测试复用；不是WebKit子资源拦截器。
/// 同时支持立即响应和显式释放的阻塞响应；不以sleep模拟状态同步。
final class RSSPageFixtureProtocol: URLProtocol, @unchecked Sendable {
    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RSSPageFixtureProtocol.self]
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        return URLSession(configuration: configuration)
    }

    struct Response: Sendable {
        var body: Data
        var status = 200
        var contentType = "text/html; charset=utf-8"
        var headers: [String: String] = [:]
        var held = false
    }

    private struct Fixture {
        var fallback: Response?
        var sequences: [String: [Response]] = [:]
        var offsets: [String: Int] = [:]
        var requests: [URLRequest] = []
        var requestTimes: [Date] = []
        var pending: [(RSSPageFixtureProtocol, Response)] = []
        var events: AsyncStream<URLRequest>.Continuation?
    }
    private let lifecycle = OSAllocatedUnfairLock(initialState: false)
    private static let state = OSAllocatedUnfairLock(initialState: [String: Fixture]())
    // 常驻当前测试进程但只匹配仍登记的host；一个suite结束不能移除另一个suite的handler。
    private static let registered = URLProtocol.registerClass(RSSPageFixtureProtocol.self)

    static func serve(host: String, contentType: String, body: Data) {
        precondition(registered)
        state.withLock { $0[host] = Fixture(fallback: Response(body: body, contentType: contentType)) }
    }

    static func serve(host: String, sequences: [String: [Response]], events: AsyncStream<URLRequest>.Continuation? = nil) {
        precondition(registered)
        state.withLock { $0[host] = Fixture(sequences: sequences, events: events) }
    }

    static func requestTimes(host: String) -> [Date] { state.withLock { $0[host]?.requestTimes ?? [] } }
    static func release(host: String) {
        let pending = state.withLock { fixtures in
            let pending = fixtures[host]?.pending ?? []
            fixtures[host]?.pending = []
            return pending
        }
        for (loader, response) in pending { loader.deliver(response) }
    }

    static func requests(host: String) -> [URLRequest] { state.withLock { $0[host]?.requests ?? [] } }
    static func remove(host: String) { _ = state.withLock { $0.removeValue(forKey: host) } }

    override class func canInit(with request: URLRequest) -> Bool {
        guard let host = request.url?.host else { return false }
        return state.withLock { $0[host] != nil }
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let request = self.request
        guard let url = request.url, let host = url.host else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let result = Self.state.withLock { fixtures -> Response? in
            guard var fixture = fixtures[host], fixture.requests.count < 128 else { return nil }
            fixture.requests.append(request)
            fixture.requestTimes.append(Date())
            fixture.events?.yield(request)
            let response: Response
            if let sequence = fixture.sequences[url.path] {
                let offset = fixture.offsets[url.path, default: 0]
                guard sequence.indices.contains(offset) else {
                    fixtures[host] = fixture
                    return nil
                }
                fixture.offsets[url.path] = offset + 1
                response = sequence[offset]
            } else if let fallback = fixture.fallback {
                response = fallback
            } else {
                fixtures[host] = fixture
                return nil
            }
            if response.held { fixture.pending.append((self, response)) }
            fixtures[host] = fixture
            return response
        }
        guard let result else {
            client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable))
            return
        }
        if !result.held { deliver(result) }
    }

    private func deliver(_ result: Response) {
        let mayDeliver = lifecycle.withLock { finished in
            guard !finished else { return false }
            finished = true
            return true
        }
        guard mayDeliver else { return }
        guard let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: result.status, httpVersion: nil,
                                             headerFields: result.headers.merging(["Content-Type": result.contentType]) { existing, _ in existing }) else {
            client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: result.body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { lifecycle.withLock { $0 = true } }
}
