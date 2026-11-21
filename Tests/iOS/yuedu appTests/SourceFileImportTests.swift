import Foundation
import Combine
import Testing
@testable import yuedu_app

@Suite("文件型书源下载导入", .serialized, .timeLimit(.minutes(2)))
@MainActor
struct SourceFileImportTests {
    private func root() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SourceFileImportTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
    private func clean(_ directory: URL) {
        do { try FileManager.default.removeItem(at: directory) }
        catch { Issue.record("隔离测试目录清理失败") }
    }
    private func source(host: String) -> BookSource {
        var source = BookSource(bookSourceUrl: "https://" + host, bookSourceName: "合成文件源")
        source.bookSourceType = 3
        source.header = #"{"X-File":"fixture","User-Agent":"FixtureFileAgent"}"#
        return source
    }
    private func book(source: BookSource, rawURL: String) -> OnlineBook {
        OnlineBook(name: "合成导入书", author: "合成作者", intro: "", coverUrl: "", bookUrl: source.bookSourceUrl + "/book",
            tocUrl: "", wordCount: "", lastChapter: "", kind: "", sourceId: source.id, sourceName: source.bookSourceName,
            runtimeVariables: ["downloadID": "42"], downloadUrls: [rawURL])
    }

    @Test("取消下载列表加载也要取消在途请求，晚到结果不能改回ready")
    func cancelsLoadingModel() async throws {
        let directory = try root(); defer { clean(directory) }
        let host = UUID().uuidString.lowercased() + ".fixture.invalid"
        let session = RSSPageFixtureProtocol.makeSession()
        let events = AsyncStream<URLRequest>.makeStream()
        RSSPageFixtureProtocol.serve(host: host, sequences: ["/book": [.init(body: Data("<h1>书名</h1><a href='/book.txt'>下载</a>".utf8), held: true)]], events: events.continuation)
        defer { session.invalidateAndCancel(); RSSPageFixtureProtocol.remove(host: host) }
        var source = source(host: host); source.ruleBookInfo.downloadUrls = "a@href"
        let sources = BookSourceStore(directory: directory.appendingPathComponent("sources")); await sources.waitUntilLoaded()
        try sources.importSelected([source], options: .direct); try await sources.persistPendingChanges()
        let model = SourceFileImportModel(book: book(source: source, rawURL: "https://\(host)/book.txt"))
        let fetcher = LiveBookSourceFetcher(bookSourceFetcher: BookSourceFetcher(webFetcher: WebFetcher(session: session)))
        let task = Task { await model.load(fetcher: fetcher, sources: sources) }
        var iterator = events.stream.makeAsyncIterator(); _ = await iterator.next()
        model.cancel()
        RSSPageFixtureProtocol.release(host: host)
        await task.value
        #expect(model.phase == .failed)
    }

    @Test("本地解析期间源被删除，撤销本次新建条目而不是保留过期书")
    func invalidationDuringLocalImport() async throws {
        let directory = try root(); defer { clean(directory) }
        let host = UUID().uuidString.lowercased() + ".fixture.invalid"
        let session = RSSPageFixtureProtocol.makeSession()
        RSSPageFixtureProtocol.serve(host: host, contentType: "text/plain", body: Data("第一章\n测试正文".utf8))
        defer { session.invalidateAndCancel(); RSSPageFixtureProtocol.remove(host: host) }
        let source = source(host: host)
        let sources = BookSourceStore(directory: directory.appendingPathComponent("sources")); await sources.waitUntilLoaded()
        try sources.importSelected([source], options: .direct); try await sources.persistPendingChanges()
        let store = BookStore(metadataFileURL: directory.appendingPathComponent("books.json"))
        let observer = store.shelfPublisher.dropFirst().sink { rows in
            if !rows.isEmpty { sources.delete(id: source.id) }
        }
        defer { observer.cancel() }
        let raw = "https://\(host)/book.txt"
        await #expect(throws: SourceFileImportService.Failure.self) {
            _ = try await SourceFileImportService.importFile(rawURL: raw, book: book(source: source, rawURL: raw),
                source: source, sources: sources, store: store, requestSession: session)
        }
        #expect(store.books.isEmpty)
        for book in store.books { store.delete(bookId: book.id) }
        await BookStore.queuedWritesLanded(); try await sources.persistPendingChanges()
    }

    @Test("生产请求和本地导入链保留POST、变量、头部、原始文件及书架状态")
    func importsActualTXT() async throws {
        let directory = try root(); defer { clean(directory) }
        let bytes = Data("第一章\n真实导入测试正文。\n第二章\n第二章内容。\n".utf8)
        let server = try VideoStillFixtureServer(directory: directory, routes: [
            "/download": .init(body: bytes, type: "text/plain", allowedMethods: ["POST"])
        ], maximumRequests: 4)
        let base = try await server.start()
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel(); server.stop() }
        var source = source(host: "127.0.0.1")
        source.bookSourceUrl = base.absoluteString
        let sources = BookSourceStore(directory: directory.appendingPathComponent("sources")); await sources.waitUntilLoaded()
        try sources.importSelected([source], options: .direct); try await sources.persistPendingChanges()
        let raw = base.appendingPathComponent("download").absoluteString + ", {\"method\":\"POST\",\"body\":\"id={{java.get('downloadID')}}\",\"type\":\"txt\"}"
        let store = BookStore(metadataFileURL: directory.appendingPathComponent("books.json"))
        let imported = try await SourceFileImportService.importFile(rawURL: raw, book: book(source: source, rawURL: raw),
            source: source, sources: sources, store: store, requestSession: session)
        defer { store.delete(bookId: imported.id) }
        #expect(!imported.isOnline && imported.isInBookshelf && imported.contentPipelineKind == .txt)
        #expect(imported.title == "合成导入书" && imported.author == "合成作者")
        #expect(try Data(contentsOf: StorageLocations.bookFile(imported.contentFilename)) == bytes)
        #expect(BookStore(metadataFileURL: directory.appendingPathComponent("books.json")).books.contains { $0.id == imported.id })
        let request = try #require(server.requests.first)
        #expect(server.requests.count == 1)
        #expect(request.method == "POST")
        #expect(request.headers["x-file"] == "fixture")
        #expect(request.headers["user-agent"] == "FixtureFileAgent")
        #expect(String(data: request.body, encoding: .utf8) == "id=42")
        #expect(DetailPageKind(.file) == .file)
        store.delete(bookId: imported.id)
        await BookStore.queuedWritesLanded()
    }

    @Test("空下载规则和明确不支持的后缀不能伪装成文本书")
    func invalidTargets() async throws {
        let source = source(host: UUID().uuidString + ".fixture.invalid")
        await #expect(throws: ModernParserBridgeError.self) {
            _ = try await BookSourceSession.session(for: source).parse { bridge in
                try bridge.parseBookInfo(html: "<h1>无链接</h1>", bookUrl: source.bookSourceUrl, baseURL: source.bookSourceUrl, source: source)
            }
        }
        let response = try #require(HTTPURLResponse(url: URL(string: "https://example.invalid/book.txt")!, statusCode: 200,
            httpVersion: nil, headerFields: ["Content-Type": "text/plain"]))
        #expect(throws: SourceFileImportService.Failure.self) {
            _ = try SourceFileImportService.fileExtension(type: "umd", response: response)
        }
    }

    @Test("删除源后晚到响应不得导入书架")
    func deletionRejectsLateResponse() async throws {
        let directory = try root(); defer { clean(directory) }
        let host = UUID().uuidString.lowercased() + ".fixture.invalid"
        let session = RSSPageFixtureProtocol.makeSession()
        let events = AsyncStream<URLRequest>.makeStream()
        RSSPageFixtureProtocol.serve(host: host, sequences: ["/book.txt": [.init(body: Data("第一章\n正文".utf8), contentType: "text/plain", held: true)]], events: events.continuation)
        defer { session.invalidateAndCancel(); RSSPageFixtureProtocol.remove(host: host) }
        let source = source(host: host)
        let sources = BookSourceStore(directory: directory.appendingPathComponent("sources")); await sources.waitUntilLoaded()
        try sources.importSelected([source], options: .direct); try await sources.persistPendingChanges()
        let raw = "https://\(host)/book.txt"
        let store = BookStore(metadataFileURL: directory.appendingPathComponent("books.json"))
        let value = book(source: source, rawURL: raw)
        let task = Task { try await SourceFileImportService.importFile(rawURL: raw, book: value, source: source, sources: sources, store: store, requestSession: session) }
        var iterator = events.stream.makeAsyncIterator()
        _ = await iterator.next()
        sources.delete(id: source.id); try await sources.persistPendingChanges()
        RSSPageFixtureProtocol.release(host: host)
        await #expect(throws: SourceFileImportService.Failure.self) { _ = try await task.value }
        #expect(store.books.isEmpty)
    }

    @Test("取消真实在途请求后无书架条目")
    func cancellationRejectsImport() async throws {
        let directory = try root(); defer { clean(directory) }
        let host = UUID().uuidString.lowercased() + ".fixture.invalid"
        let session = RSSPageFixtureProtocol.makeSession()
        let events = AsyncStream<URLRequest>.makeStream()
        RSSPageFixtureProtocol.serve(host: host, sequences: ["/book.txt": [.init(body: Data("第一章\n正文".utf8), contentType: "text/plain", held: true)]], events: events.continuation)
        defer { session.invalidateAndCancel(); RSSPageFixtureProtocol.remove(host: host) }
        let source = source(host: host)
        let sources = BookSourceStore(directory: directory.appendingPathComponent("sources")); await sources.waitUntilLoaded()
        try sources.importSelected([source], options: .direct); try await sources.persistPendingChanges()
        let raw = "https://\(host)/book.txt"
        let store = BookStore(metadataFileURL: directory.appendingPathComponent("books.json"))
        let value = book(source: source, rawURL: raw)
        let task = Task { try await SourceFileImportService.importFile(rawURL: raw, book: value, source: source, sources: sources, store: store, requestSession: session) }
        var iterator = events.stream.makeAsyncIterator(); _ = await iterator.next()
        task.cancel()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        #expect(store.books.isEmpty)
    }

    @Test("HTTP错误和响应超限不保存文件书")
    func responseFailures() async throws {
        let directory = try root(); defer { clean(directory) }
        let host = UUID().uuidString.lowercased() + ".fixture.invalid"
        let session = RSSPageFixtureProtocol.makeSession()
        RSSPageFixtureProtocol.serve(host: host, sequences: [
            "/denied.txt": [.init(body: Data("禁止".utf8), status: 403, contentType: "text/plain")],
            "/large.txt": [.init(body: Data(repeating: 65, count: 64), contentType: "text/plain")]
        ])
        defer { session.invalidateAndCancel(); RSSPageFixtureProtocol.remove(host: host) }
        let source = source(host: host)
        let sources = BookSourceStore(directory: directory.appendingPathComponent("sources")); await sources.waitUntilLoaded()
        try sources.importSelected([source], options: .direct); try await sources.persistPendingChanges()
        let store = BookStore(metadataFileURL: directory.appendingPathComponent("books.json"))
        for path in ["/denied.txt", "/large.txt"] {
            let raw = "https://\(host)\(path)"
            await #expect(throws: (any Error).self) {
                _ = try await SourceFileImportService.importFile(rawURL: raw, book: book(source: source, rawURL: raw),
                    source: source, sources: sources, store: store, requestSession: session, limit: 32)
            }
        }
        #expect(store.books.isEmpty)
    }
}
