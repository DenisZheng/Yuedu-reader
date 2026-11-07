import Foundation
import os

/// 仅接管显式登记的合成host，供RSS的URLSession固定响应测试复用；不是WebKit子资源拦截器。
/// RSS现状会把HTTP升级到HTTPS，这里保留真实生成的请求，仅替代最后的网络响应。
final class RSSPageFixtureProtocol: URLProtocol {
    struct Response: Sendable {
        var body: Data
        var status = 200
        var contentType = "text/html; charset=utf-8"
    }

    private struct Fixture {
        var fallback: Response?
        var sequences: [String: [Response]] = [:]
        var offsets: [String: Int] = [:]
        var requests: [URLRequest] = []
    }
    private static let state = OSAllocatedUnfairLock(initialState: [String: Fixture]())
    // 常驻当前测试进程但只匹配仍登记的host；一个suite结束不能移除另一个suite的handler。
    private static let registered = URLProtocol.registerClass(RSSPageFixtureProtocol.self)

    static func serve(host: String, contentType: String, body: Data) {
        precondition(registered)
        state.withLock { $0[host] = Fixture(fallback: Response(body: body, contentType: contentType)) }
    }

    static func serve(host: String, sequences: [String: [Response]]) {
        precondition(registered)
        state.withLock { $0[host] = Fixture(sequences: sequences) }
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
            fixtures[host] = fixture
            return response
        }
        guard let result,
              let response = HTTPURLResponse(url: url, statusCode: result.status, httpVersion: nil,
                                             headerFields: ["Content-Type": result.contentType]) else {
            client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: result.body)
        client?.urlProtocolDidFinishLoading(self)
    }
    // 响应是同步内存数据，不创建需要取消的异步工作。
    override func stopLoading() {}
}
