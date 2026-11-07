import Foundation
import Testing
import os
@testable import yuedu_app

@Suite("S3 RSS WebDAV transport", .serialized)
@MainActor
struct RSSWebDAVBackupTests {
    @Test("实际WebDAV请求使用Fork路径，上传再下载校验；404和401不能混淆")
    func transferAndFailures() async throws {
        let name = "RSSWebDAV-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        defer {
            do { try FileManager.default.removeItem(at: directory) }
            catch { Issue.record("无法清理测试目录") }
        }
        let store = RSSStore(storageDirectory: directory)
        store.addSource(RSSSource(id: "backup-source", name: "Synthetic", url: "synthetic-key"))
        let item = RSSItem(id: "shared", title: "Title", link: "https://fixture.invalid", sourceId: "backup-source")
        store.mergeFetchedItems([item], for: "backup-source")
        store.toggleFavorite(articleId: item.id)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RSSWebDAVFixture.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        RSSWebDAVFixture.state.withLock { $0 = .init() }
        let manager = WebDAVManager(defaults: defaults, session: session)
        manager.serverUrl = "https://dav.invalid"
        manager.username = "synthetic"; manager.password = "synthetic"
        try await manager.backupRSS(store: store)
        let data = try #require(try await manager.downloadRSSBackup())
        try await store.restoreBackup(data)
        #expect(store.article(id: item.id)?.isFavorite == true)
        #expect(RSSWebDAVFixture.state.withLock { $0.paths } == [
            "MKCOL /readerfork-dev", "PUT /readerfork-dev/rss-v1.json", "GET /readerfork-dev/rss-v1.json"
        ])
        RSSWebDAVFixture.state.withLock { $0.status = 404 }
        #expect(try await manager.downloadRSSBackup() == nil)
        RSSWebDAVFixture.state.withLock { $0.status = 401 }
        await #expect(throws: WebDAVError.self) { try await manager.downloadRSSBackup() }
        RSSWebDAVFixture.state.withLock { $0.status = 200; $0.body = Data("broken".utf8) }
        await #expect(throws: (any Error).self) { try await manager.downloadRSSBackup() }
    }
}

private final class RSSWebDAVFixture: URLProtocol {
    struct State {
        var paths: [String] = []
        var status = 200
        var body = Data()
    }
    static let state = OSAllocatedUnfairLock(initialState: State())
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "dav.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let request = self.request
        guard let url = request.url else { client?.urlProtocol(self, didFailWithError: URLError(.badURL)); return }
        var uploaded = request.httpBody
        if request.httpMethod == "PUT", uploaded == nil, let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var body = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count >= 0 else {
                    client?.urlProtocol(self, didFailWithError: stream.streamError ?? URLError(.cannotDecodeRawData))
                    return
                }
                if count == 0 { break }
                body.append(contentsOf: buffer.prefix(count))
            }
            uploaded = body
        }
        let body = uploaded ?? Data()
        let output = Self.state.withLock { state in
            state.paths.append("\(request.httpMethod ?? "") \(url.path)")
            if request.httpMethod == "PUT" { state.body = body }
            return (state.status, state.body)
        }
        let response = HTTPURLResponse(url: url, statusCode: output.0, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: output.1)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
