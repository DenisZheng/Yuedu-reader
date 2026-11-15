import Foundation
import Testing
@testable import yuedu_app

@Suite("评审源修订隔离", .serialized)
@MainActor struct ReviewSourceRevisionTests {
    @Test("源A的发现地址与分组修改不取消源B的前台在途请求")
    func unrelatedSourceDoesNotCancelRequest() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = RSSStore(storageDirectory: directory)
        defer { if FileManager.default.fileExists(atPath: directory.path) {
            do { try FileManager.default.removeItem(at: directory) } catch { Issue.record(error) }
        } }
        let first = RSSSource(name: "A", url: "https://source-a.invalid/feed")
        let host = "source-b-" + UUID().uuidString.lowercased() + ".invalid"
        var second = RSSSource(name: "B", url: "https://\(host)/list")
        second.ruleArticles = "a"; second.ruleTitle = "text"; second.ruleLink = "href"
        store.addSource(first); store.addSource(second)
        let ticket = try #require(store.requestTicket(for: second.id))
        let session = RSSPageFixtureProtocol.makeSession()
        let (events, continuation) = AsyncStream<URLRequest>.makeStream()
        RSSPageFixtureProtocol.serve(host: host, sequences: ["/list": [.init(body: Data("<a href='/b'>B</a>".utf8), held: true)]], events: continuation)
        defer { session.invalidateAndCancel(); continuation.finish(); RSSPageFixtureProtocol.remove(host: host) }
        let running = Task { try await LegadoRSSScraper.scrape(source: second, owner: store, requestSession: session) }
        var iterator = events.makeAsyncIterator()
        #expect(await iterator.next() != nil)
        store.applyResolvedFeedURL("https://source-a.invalid/resolved", homepageURL: nil, to: first.id)
        _ = store.addFolder(named: "Unrelated")
        #expect(store.accepts(ticket))
        RSSPageFixtureProtocol.release(host: host)
        let result = try await running.value
        #expect(result.first?.title == "B")
        #expect(RSSPageFixtureProtocol.requests(host: host).count == 1)
        try await store.flushPersistence()
    }
}
