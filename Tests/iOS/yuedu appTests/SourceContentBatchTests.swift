import Foundation
import os
import Testing
@testable import yuedu_app

@Suite("批量正文固定输入合同", .serialized)
@MainActor
struct SourceContentBatchTests {
    @Test("批量规则进入已知模型而不只保留在未知JSON")
    func batchFieldsAreExecutableConfiguration() throws {
        let rule = try JSONDecoder().decode(ContentRule.self, from: Data(#"{"contentBatch":"result.forEach(function(c){java.cacheContent(c,'批量正文');});","maxBatchSize":3}"#.utf8))
        let json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(rule)) as? [String: Any])
        #expect(json["maxBatchSize"] as? Int == 3)
        #expect((json["contentBatch"] as? String)?.contains("cacheContent") == true)
    }

    @Test("主脚本生产正文宿主提供批量回存桥")
    func cacheBridgeExistsOnProductionHost() async throws {
        let source = try MainJsSourceTests.source(script: "function getContent(){return typeof java.cacheContent;}")
        let content = try await BookSourceSession(source: source).parse {
            try $0.mainJsContent(chapter: OnlineChapterRef(index: 0, title: "第一章", url: "https://batch.invalid/1"), nextChapterURL: nil)
        }
        #expect(content == "function")
    }

    static func source(mainJs: Bool = true, batch: String? = nil) -> BookSource {
        var source = BookSource(bookSourceUrl: "https://batch-" + UUID().uuidString.lowercased() + ".invalid", bookSourceName: "批量固定源")
        source.ruleContent.maxBatchSize = 3
        let body = batch ?? "chapters.forEach(function(c){java.cacheContent(c,'批量'+c.index+'|'+c.getVariable('token'));});"
        if mainJs { source.mainJs = "function getContentBatch(chapters,book){" + body + "}function getContent(c){return '单章'+c.index;}" }
        else { source.ruleContent.contentBatch = "@js: var chapters=result;" + body }
        return source
    }
    static func refs() -> [OnlineChapterRef] {
        (0..<3).map { OnlineChapterRef(index: $0, title: "第\($0)章", url: "https://batch.invalid/read/\($0)", runtimeVariables: ["token":"变量\($0)"]) }
    }
    static func book(id: UUID, sourceId: UUID) -> ReadingBook {
        var book = ReadingBook(id: id, title: "并发批量", contentFilename: "")
        book.isOnline = true; book.bookSourceId = sourceId; book.onlineChapters = refs(); book.contentPipelineKind = .html
        return book
    }

    static func root() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SourceBatch-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
    static func cleanup(_ root: URL) {
        do { try FileManager.default.removeItem(at: root) } catch { Issue.record("批量测试目录清理失败") }
    }

    @Test("两种源真实逐章回存、章节变量隔离，重复批次不重写文件")
    func bothKindsAndNoOp() async throws {
        for main in [true, false] {
            let root = try Self.root(); defer { Self.cleanup(root) }
            let repo = ChapterCacheRepository(rootDirectory: root), source = Self.source(mainJs: main), id = UUID()
            let fetcher = BookSourceFetcher(), refs = Self.refs()
            let missing = try await fetcher.fetchContentBatch(refs: refs, bookId: id, source: source, repository: repo)
            #expect(missing.isEmpty)
            for ref in refs {
                #expect(repo.loadChapterPackageSync(bookId: id, chapterIndex: ref.index)?.content == "批量\(ref.index)|变量\(ref.index)")
            }
            let files = try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent(id.uuidString), includingPropertiesForKeys: [.contentModificationDateKey])
            let dates = try files.map { try $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate }
            #expect(try await fetcher.fetchContentBatch(refs: refs, bookId: id, source: source, repository: repo).isEmpty)
            #expect(try files.map { try $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate } == dates)
        }
    }

    @Test("缺可选函数和未回存部分保留本批顺序")
    func missingChapters() async throws {
        let root = try Self.root(); defer { Self.cleanup(root) }
        let repo = ChapterCacheRepository(rootDirectory: root), id = UUID(), refs = Self.refs(), fetcher = BookSourceFetcher()
        let partial = Self.source(batch: "java.cacheContent(chapters[2],'第三');java.cacheContent(chapters[0],'第一');")
        #expect(try await fetcher.fetchContentBatch(refs: refs, bookId: id, source: partial, repository: repo).map(\.index) == [1])
        var absent = Self.source(); absent.mainJs = "function getContent(c){return '单章';}"
        #expect(try await fetcher.fetchContentBatch(refs: refs, bookId: UUID(), source: absent, repository: repo).map(\.index) == [0,1,2])
    }

    @Test("同URL对象按index回存；URL字符串和数字不用于错误消歧")
    func identity() async throws {
        let root = try Self.root(); defer { Self.cleanup(root) }
        let repo = ChapterCacheRepository(rootDirectory: root), id = UUID(), fetcher = BookSourceFetcher()
        let refs = (0..<3).map { OnlineChapterRef(index: $0, title: "第\($0)章", url: "https://batch.invalid/same") }
        let source = Self.source(batch: "java.cacheContent(chapters[1],'第二');java.cacheContent(chapters[0],'第一');java.cacheContent(chapters[2],'第三');")
        #expect(try await fetcher.fetchContentBatch(refs: refs, bookId: id, source: source, repository: repo).isEmpty)
        #expect(repo.loadChapterPackageSync(bookId: id, chapterIndex: 0)?.content == "第一")
        #expect(repo.loadChapterPackageSync(bookId: id, chapterIndex: 1)?.content == "第二")
        for identifier in ["chapters[0].url", "0", "{index:100}"] {
            let bad = Self.source(batch: "java.cacheContent(" + identifier + ",'错误');")
            await #expect(throws: (any Error).self) { try await fetcher.fetchContentBatch(refs: refs, bookId: UUID(), source: bad, repository: repo) }
        }
    }

    @Test("缓存owner的版本票据拒绝清理／单章新写之后的旧批量回存")
    func staleCacheWrites() async throws {
        let root = try Self.root(); defer { Self.cleanup(root) }
        try await Task.detached {
            let repo = ChapterCacheRepository(rootDirectory: root), id = UUID()
            let old = repo.beginWrite(bookId: id, chapterIndex: 0)
            try repo.saveToCache(content: "更新正文", bookId: id, chapterIndex: 0)
            #expect(throws: ChapterCacheWriteError.staleWrite) { try repo.saveToCache(content: "旧正文", bookId: id, chapterIndex: 0, writeTicket: old) }
            #expect(repo.loadChapterPackageSync(bookId: id, chapterIndex: 0)?.content == "更新正文")
            let token = repo.beginWrite(bookId: id, chapterIndex: 0)
            repo.clearAllChapterCache(bookId: id)
            #expect(throws: ChapterCacheWriteError.staleWrite) { try repo.saveToCache(content: "不得复活", bookId: id, chapterIndex: 0, writeTicket: token) }
            #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(id.uuidString).path))
        }.value
    }

    @Test("批量替换规则读取当前章而不是上一章上下文")
    func replacementContext() async throws {
        let root = try Self.root(); defer { Self.cleanup(root) }
        var source = Self.source(batch: "chapters.forEach(function(c){java.cacheContent(c,'正文');});")
        source.ruleContent.replaceRegex = "@js: result+'|'+chapter.index+'|'+chapter.getVariable('token')"
        let repo = ChapterCacheRepository(rootDirectory: root), id = UUID()
        #expect(try await BookSourceFetcher().fetchContentBatch(refs: Self.refs(), bookId: id, source: source, repository: repo).isEmpty)
        for index in 0..<3 {
            #expect(repo.loadChapterPackageSync(bookId: id, chapterIndex: index)?.content.trimmingCharacters(in: .whitespacesAndNewlines) == "正文|\(index)|变量\(index)")
        }
    }

    @Test("两种批量规则中章节写入和删除在当次替换可见，不串到相邻章节")
    func mutatedChapterVariablesAndRawContent() async throws {
        let root = try Self.root(); defer { Self.cleanup(root) }
        let repo = ChapterCacheRepository(rootDirectory: root)
        let raw = "<p>替换前</p>"
        for main in [true, false] {
            let id = UUID()
            let body = """
                chapters[0].putVariable('token', '本批新值');
                chapters[1].putVariable('token', null);
                java.cacheContent(chapters[0], '<p>替换前</p>');
                java.cacheContent(chapters[1], '替换前');
                java.cacheContent(chapters[2], '替换前');
                """
            var source = Self.source(mainJs: main, batch: body)
            source.ruleContent.replaceRegex = "@js: '已替换|' + chapter.index + '|' + chapter.getVariable('token') + '|' + java.get('token')"
            let missing = try await BookSourceFetcher().fetchContentBatch(refs: Self.refs(), bookId: id,
                source: source, repository: repo)
            #expect(missing.isEmpty)
            for (index, token) in [(0, "本批新值"), (1, ""), (2, "变量2")] {
                let package = try #require(repo.loadChapterPackageSync(bookId: id, chapterIndex: index))
                #expect(package.content.trimmingCharacters(in: .whitespacesAndNewlines) == "已替换|\(index)|\(token)|\(token)")
                if index == 0 {
                    let filename = try #require(package.rawHTMLFilename)
                    let bytes = try Data(contentsOf: root.appendingPathComponent(id.uuidString).appendingPathComponent(filename))
                    #expect(String(decoding: bytes, as: UTF8.self) == raw)
                } else {
                    #expect(package.rawHTMLFilename == nil && package.normalizedHTMLFilename == nil)
                }
            }
        }
    }

    @Test("同次批量中未回存的章节把变量快照交给单章回退；其他章保留自己的变量")
    func batchVariablesReachSingleFallback() async throws {
        var fixture = Self.source(batch: """
            chapters[0].putVariable('token', '回退变量0');
            java.cacheContent(chapters[1], '批量1');
            java.cacheContent(chapters[2], '批量2');
            """)
        fixture.mainJs = try #require(fixture.mainJs).replacingOccurrences(of: "return '单章'+c.index;",
                                                                         with: "return '单章'+c.index+'|'+c.getVariable('token');")
        let source = fixture
        let fetcher = BookSourceFetcher()
        let manager = ChapterFetchManager(bookSourceFetcher: fetcher, sourceLookup: { _ in source })
        let id = UUID()
        defer { fetcher.clearAllChapterCache(bookId: id) }
        let book = Self.book(id: id, sourceId: source.id)
        let fallback = try await manager.fetchChapter(book: book, chapterIndex: 0, priority: .download, store: nil)
        #expect(fallback.content.contains("单章0|回退变量0"))
        let adjacent = try await manager.fetchChapter(book: book, chapterIndex: 1, priority: .download, store: nil)
        #expect(adjacent.content == "批量1")
        #expect(book.onlineChapters?.first?.runtimeVariables?["token"] == "变量0")
    }

    @Test("批量选章用清洗后的 URL 命中已缓存邻章，回存直接返回批量结果")
    func batchCandidatesUseCanonicalURL() async throws {
        let source = Self.source(batch: "chapters.forEach(function(c){java.cacheContent(c,'批量|'+chapters.length+'|'+c.index);});")
        let fetcher = BookSourceFetcher()
        let manager = ChapterFetchManager(bookSourceFetcher: fetcher, sourceLookup: { _ in source })
        let id = UUID()
        defer { fetcher.clearAllChapterCache(bookId: id) }
        let canonical = Self.refs()
        var book = Self.book(id: id, sourceId: source.id)
        book.onlineChapters = canonical.map { ref in
            var wrapped = ref
            wrapped.url = "<a href=\"\(ref.url)\">\(ref.title)</a>"
            return wrapped
        }
        try fetcher.saveToCache(content: "已有正文，不可重抓", bookId: id, chapterIndex: 1,
            sourceURL: canonical[1].url, tocTitle: canonical[1].title)
        let result = try await manager.fetchChapter(book: book, chapterIndex: 0, priority: .download, store: nil)
        #expect(result.content == "批量|2|0")
        #expect(result.rawHTMLFilename == nil && result.normalizedHTMLFilename == nil)
        #expect(fetcher.loadChapterPackageSync(bookId: id, chapterIndex: 0)?.savedAt == result.savedAt)
        let kept = try await manager.fetchChapter(book: book, chapterIndex: 1, priority: .download, store: nil)
        #expect(kept.content == "已有正文，不可重抓")
        let adjacent = try await manager.fetchChapter(book: book, chapterIndex: 2, priority: .download, store: nil)
        #expect(adjacent.content == "批量|2|2")
    }

    @Test("取消／源失效／清缓存拒绝网络之后的批量晚到回存")
    func lateBatchResults() async throws {
        for mode in ["cancel", "invalidate", "clear"] {
            let root = try Self.root(); defer { Self.cleanup(root) }
            let host = "batch-held-" + UUID().uuidString.lowercased() + ".invalid"
            let events = AsyncStream<URLRequest>.makeStream()
            RSSPageFixtureProtocol.serve(host: host, sequences: ["/batch": [.init(body: Data("响应".utf8), held: true)]], events: events.continuation)
            defer { RSSPageFixtureProtocol.remove(host: host) }
            let source = Self.source(batch: "java.ajax('https://" + host + "/batch');chapters.forEach(function(c){java.cacheContent(c,'不得晚到');});")
            let session = BookSourceSession(source: source, requestSession: RSSPageFixtureProtocol.makeSession())
            let repo = ChapterCacheRepository(rootDirectory: root), id = UUID(), fetcher = BookSourceFetcher(), refs = Self.refs()
            let task = Task { try await fetcher.fetchContentBatch(refs: refs, bookId: id, source: source, repository: repo, session: session) }
            var iterator = events.stream.makeAsyncIterator()
            _ = try #require(await iterator.next())
            if mode == "cancel" { task.cancel() }
            else if mode == "invalidate" { session.invalidate() }
            else { repo.clearAllChapterCache(bookId: id) }
            RSSPageFixtureProtocol.release(host: host)
            await #expect(throws: (any Error).self) { try await task.value }
            #expect(repo.loadChapterPackageSync(bookId: id, chapterIndex: 0) == nil)
            #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(id.uuidString).path))
        }
    }

    @Test("声明式包装、空回存、数量限制与批量异常保留已成功章")
    func wrappersAndLimits() async throws {
        let root = try Self.root(); defer { Self.cleanup(root) }
        let repo = ChapterCacheRepository(rootDirectory: root), fetcher = BookSourceFetcher(), refs = Self.refs()
        for rule in ["var chapters=result;java.cacheContent(chapters[0],'一');", "<js>java.cacheContent(result[0],'一');</js><js>java.cacheContent(result[1],'二');</js>"] {
            var source = Self.source(mainJs: false); source.ruleContent.contentBatch = rule
            let expected = rule.hasPrefix("<js>") ? [2] : [1,2]
            #expect(try await fetcher.fetchContentBatch(refs: refs, bookId: UUID(), source: source, repository: repo).map(\.index) == expected)
        }
        let id = UUID(), bad = Self.source(batch: "java.cacheContent(chapters[0],'已完成');throw Error('固定失败');")
        await #expect(throws: (any Error).self) { try await fetcher.fetchContentBatch(refs: refs, bookId: id, source: bad, repository: repo) }
        #expect(repo.loadChapterPackageSync(bookId: id, chapterIndex: 0)?.content == "已完成")
        let empty = Self.source(batch: "chapters.forEach(function(c){java.cacheContent(c,'  ');});")
        #expect(try await fetcher.fetchContentBatch(refs: refs, bookId: UUID(), source: empty, repository: repo).count == 3)
        var limited = Self.source(); limited.ruleContent.maxBatchSize = 2
        #expect(try await fetcher.fetchContentBatch(refs: refs, bookId: UUID(), source: limited, repository: repo).map(\.index) == [2])
        limited.ruleContent.maxBatchSize = 100
        #expect(limited.contentBatchSize == 50)
    }

    @Test("批量回存中的替换不能清掉后续java解析回调")
    func replacementPreservesRuleCallbacks() async throws {
        let root = try Self.root(); defer { Self.cleanup(root) }
        let control = ModernRuleEngine()
        control.setContent("", baseUrl: "https://batch.invalid/")
        #expect(control.getString(ruleStr: "p@text", mContent: "<p>正文</p>") == "正文")
        var source = Self.source(mainJs: false)
        source.ruleContent.contentBatch = "@js: result.forEach(function(c){var text=java.getString('p@text','<p>正文</p>');java.cacheContent(c,text);});"
        source.ruleContent.replaceRegex = "@js: result"
        let id = UUID(), repo = ChapterCacheRepository(rootDirectory: root)
        let missing = try await BookSourceFetcher().fetchContentBatch(refs: Self.refs(), bookId: id, source: source, repository: repo)
        let bodies = (0..<3).map { repo.loadChapterPackageSync(bookId: id, chapterIndex: $0)?.content ?? "<未回存>" }
        #expect(missing.map(\.index) == [], Comment(rawValue: "固定回传=" + bodies.joined(separator: "|")))
    }

    @Test("并行下载与预读合并批量；异常只回退未完成章")
    func sharedBatchAndPartialFallback() async throws {
        let source = Self.source(batch: "var n=bumpBatch();chapters.forEach(function(c){java.cacheContent(c,'批次'+n+'章'+c.index);});")
        var sourceWithLibrary = source
        sourceWithLibrary.jsLib = "var batches=0;function bumpBatch(){return ++batches;}"
        var book = ReadingBook(title: "并发批量", contentFilename: "")
        book.isOnline = true; book.bookSourceId = source.id; book.onlineChapters = Self.refs(); book.contentPipelineKind = .html
        let fetcher = BookSourceFetcher(), stableSource = sourceWithLibrary
        let manager = ChapterFetchManager(bookSourceFetcher: fetcher, sourceLookup: { _ in stableSource })
        defer { fetcher.clearAllChapterCache(bookId: book.id) }
        let bookID = book.id, sourceID = source.id
        async let first = manager.fetchChapter(book: Self.book(id: bookID, sourceId: sourceID), chapterIndex: 0, priority: .download, store: nil)
        async let second = manager.fetchChapter(book: Self.book(id: bookID, sourceId: sourceID), chapterIndex: 1, priority: .prefetch, store: nil)
        async let third = manager.fetchChapter(book: Self.book(id: bookID, sourceId: sourceID), chapterIndex: 2, priority: .download, store: nil)
        let packages = try await [first, second, third]
        #expect(packages.map(\.content) == ["批次1章0", "批次1章1", "批次1章2"])
        let partial = Self.source(batch: "java.cacheContent(chapters[0],'批量完成');throw Error('固定失败');")
        let partialManager = ChapterFetchManager(bookSourceFetcher: fetcher, sourceLookup: { _ in partial })
        let partialBook = ReadingBook(id: UUID(), title: "部分回退", contentFilename: "")
        var current = partialBook; current.isOnline = true; current.bookSourceId = partial.id
        current.onlineChapters = Self.refs(); current.contentPipelineKind = .html
        defer { fetcher.clearAllChapterCache(bookId: current.id) }
        let p0 = try await partialManager.fetchChapter(book: current, chapterIndex: 0, priority: .download, store: nil)
        let p1 = try await partialManager.fetchChapter(book: current, chapterIndex: 1, priority: .download, store: nil)
        #expect(p0.content == "批量完成" && p1.content.contains("单章1"))
    }

    @Test("声明式数量兼容整数值字符串和浮点；坏值仅关闭批量并保留其他规则")
    func tolerantBatchSize() throws {
        for (value, expected) in [("\"10\"", 10), ("10.0", 10), ("\" 10.0 \"", 10),
                                  ("true", 1), ("2.5", 1), ("{}", 1), ("null", 1), ("1e20", 1)] {
            let rule = #"{"content":"body","subContent":"aside","contentBatch":"// 固定","maxBatchSize":"# + value + "}"
            for encoded in [false, true] {
                let json = try JSONSerialization.data(withJSONObject: [
                    "bookSourceName": "固定", "bookSourceUrl": "https://batch.invalid",
                    "ruleContent": encoded ? rule : JSONSerialization.jsonObject(with: Data(rule.utf8))
                ])
                let source = try JSONDecoder().decode(BookSource.self, from: json)
                #expect(source.ruleContent.content == "body" && source.ruleContent.subContent == "aside")
                #expect(source.contentBatchSize == expected, Comment(rawValue: value))
            }
        }
    }

    @Test("批量回传字节预算明确拒绝")
    func batchByteBudget() async throws {
        let root = try Self.root(); defer { Self.cleanup(root) }
        let source = Self.source(batch: "java.cacheContent(chapters[0],new Array(17*1024*1024+1).join('x'));")
        await #expect(throws: SourceContentBatch.Failure.self) {
            try await BookSourceFetcher().fetchContentBatch(refs: Self.refs(), bookId: UUID(), source: source,
                repository: ChapterCacheRepository(rootDirectory: root))
        }
    }

    @Test("关闭预读者不会取消仍共享批量任务的下载者")
    func sharedCancellation() async throws {
        let root = try Self.root(); defer { Self.cleanup(root) }
        let server = try VideoStillFixtureServer(directory: root, maximumRequests: 3)
        let requests = AsyncStream<Void>.makeStream(), joins = AsyncStream<Int>.makeStream()
        let gate = DispatchSemaphore(value: 0)
        server.route { _ in
            dispatchPrecondition(condition: .notOnQueue(.main))
            requests.continuation.yield(())
            gate.wait() // 只暂停这个有限本机响应，收到测试的明确释放信号后返回。
            return .init(body: Data("响应".utf8))
        }
        let url = try await server.start()
        defer { gate.signal(); server.stop() }
        let source = Self.source(batch: "java.ajax('" + url.absoluteString + "held');chapters.forEach(function(c){java.cacheContent(c,'共享下载'+c.index);});")
        let fetcher = BookSourceFetcher(), manager = ChapterFetchManager(bookSourceFetcher: BookSourceFetcher(), sourceLookup: { _ in source })
        let id = UUID(), sourceID = source.id
        defer { fetcher.clearAllChapterCache(bookId: id) }
        await manager.observeBatchWaiters { joins.continuation.yield($0) }
        let reader = Task { try await manager.fetchChapter(book: Self.book(id: id, sourceId: sourceID), chapterIndex: 0, priority: .prefetch, store: nil) }
        var requestIterator = requests.stream.makeAsyncIterator(), joinIterator = joins.stream.makeAsyncIterator()
        _ = try #require(await requestIterator.next())
        let download = Task { try await manager.fetchChapter(book: Self.book(id: id, sourceId: sourceID), chapterIndex: 1, priority: .download, store: nil) }
        while let count = await joinIterator.next() { if count == 2 { break } }
        await manager.cancelAll(for: id, includingDownloads: false)
        gate.signal()
        await #expect(throws: CancellationError.self) { try await reader.value }
        #expect(try await download.value.content == "共享下载1")
        #expect(server.requests.count == 1)
        #expect(fetcher.loadChapterPackageSync(bookId: id, chapterIndex: 2)?.content == "共享下载2")
    }

    @Test("旧批次失效，等待者尚未释放也不影响同窗口下一批")
    func completedBatchDoesNotAcceptNewWaiters() async throws {
        let host = "batch-generation-" + UUID().uuidString.lowercased() + ".invalid"
        let requests = AsyncStream<URLRequest>.makeStream()
        RSSPageFixtureProtocol.serve(host: host, sequences: ["/batch": [
            .init(body: Data("旧".utf8), held: true),
            .init(body: Data("新".utf8))
        ]], events: requests.continuation)
        defer { RSSPageFixtureProtocol.release(host: host); RSSPageFixtureProtocol.remove(host: host) }

        let source = Self.source(batch: """
            var value=java.ajax('https://\(host)/batch');
            chapters.forEach(function(c){java.cacheContent(c,value+'|'+c.index);});
            """)
        let oldSession = BookSourceSession.session(for: source, requestSession: RSSPageFixtureProtocol.makeSession())
        let id = UUID(), book = Self.book(id: id, sourceId: source.id)
        let fetcher = BookSourceFetcher()
        defer { fetcher.clearAllChapterCache(bookId: id) }
        let manager = ChapterFetchManager(bookSourceFetcher: fetcher, sourceLookup: { _ in source })
        let joins = AsyncStream<Int>.makeStream()
        let returning = AsyncStream<Void>.makeStream(), releaseWaiter = AsyncStream<Void>.makeStream()
        let held = OSAllocatedUnfairLock(initialState: false)
        await manager.observeBatchWaiters({ joins.continuation.yield($0) }, beforeRelease: {
            let hold = held.withLock { value in
                guard !value else { return false }
                value = true
                return true
            }
            if hold {
                returning.continuation.yield(())
                var iterator = releaseWaiter.stream.makeAsyncIterator()
                _ = await iterator.next()
            }
        })
        defer { releaseWaiter.continuation.finish() }
        let first = Task { try await manager.fetchChapter(book: book, chapterIndex: 0, priority: .download, store: nil) }
        defer { first.cancel() }
        var requestEvents = requests.stream.makeAsyncIterator()
        _ = try #require(await requestEvents.next())
        let second = Task { try await manager.fetchChapter(book: book, chapterIndex: 1, priority: .download, store: nil) }
        defer { second.cancel() }
        var counts = joins.stream.makeAsyncIterator()
        while let count = await counts.next(), count != 2 {}
        oldSession.invalidate()
        RSSPageFixtureProtocol.release(host: host)
        var returns = returning.stream.makeAsyncIterator()
        _ = try #require(await returns.next())

        _ = BookSourceSession.session(for: source, requestSession: RSSPageFixtureProtocol.makeSession())
        do {
            let later = try await manager.fetchChapter(book: book, chapterIndex: 2, priority: .download, store: nil)
            #expect(later.content == "新|2")
        } catch { Issue.record("新请求继承了旧批次结果：\(error)") }
        releaseWaiter.continuation.finish()
        await #expect(throws: CancellationError.self) { try await first.value }
        await #expect(throws: CancellationError.self) { try await second.value }
        #expect(RSSPageFixtureProtocol.requests(host: host).count == 2)
    }

    @Test("交付离线样本实际导入并批量读取三章")
    func offlineFixture() async throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/content-batch/offline-demo.js")
        let source = try await SourceScriptThread.run {
            let script = try String(contentsOf: url, encoding: .utf8)
            // fixture的批次计数是源持久变量；每次测试分配独立sourceKey，不污染人工验收或历史运行。
            return try MainJsSource.extract(script.replacingOccurrences(of: "batch-demo.invalid", with: "batch-fixture-" + UUID().uuidString.lowercased() + ".invalid"))
        }
        let fetcher = BookSourceFetcher()
        let book = try #require(try await fetcher.searchOutcome(query: "验收", in: source, usesCache: false).books.first)
        let info = try await fetcher.fetchBookInfoPackage(url: book.bookUrl, source: source, knownBook: book, usesCache: false)
        let toc = try await fetcher.fetchTOCPackage(tocUrl: info.tocUrl, source: source, runtimeVariables: info.runtimeVariables,
            forceRefresh: true, writesCache: false)
        let id = UUID(); defer { fetcher.clearAllChapterCache(bookId: id) }
        #expect(source.contentBatchSize == 3 && toc.chapters.count == 3)
        #expect(try await fetcher.fetchContentBatch(refs: toc.chapters, bookId: id, source: source, variables: toc.runtimeVariables ?? [:]).isEmpty)
        for index in 0..<3 {
            let content = try #require(fetcher.loadChapterPackageSync(bookId: id, chapterIndex: index)?.content)
            #expect(content.contains("批量路径") && content.contains("批次：1") && content.contains("变量\(index+1)"))
            #expect(content.contains("三章固定输入"))
        }
    }

    @Test("下载调用方只做一次批量，普通阅读仍走单章")
    func productionDownload() async throws {
        let source = Self.source(), fetcher = BookSourceFetcher(), refs = Self.refs()
        var book = ReadingBook(title: "批量验收", contentFilename: "")
        book.isOnline = true; book.bookSourceId = source.id; book.onlineChapters = refs; book.contentPipelineKind = .html
        book.runtimeVariables = ["book.name":"批量验收", "book.tocUrl":"https://batch.invalid/toc"]
        let id = book.id
        defer { fetcher.clearAllChapterCache(bookId: id) }
        let manager = ChapterFetchManager(bookSourceFetcher: fetcher, sourceLookup: { _ in source })
        let first = try await manager.fetchChapter(book: book, chapterIndex: 0, priority: .download, store: nil)
        #expect(first.content == "批量0|变量0")
        #expect(fetcher.loadChapterPackageSync(bookId: id, chapterIndex: 2)?.content == "批量2|变量2")
        var plain = book; plain = ReadingBook(title: "单章验收", contentFilename: ""); plain.isOnline = true
        plain.bookSourceId = source.id; plain.onlineChapters = refs; plain.contentPipelineKind = .html
        let single = try await manager.fetchChapter(book: plain, chapterIndex: 0, priority: .immediate, store: nil)
        defer { fetcher.clearAllChapterCache(bookId: plain.id) }
        #expect(single.content.contains("单章0"))
        #expect(fetcher.loadChapterPackageSync(bookId: plain.id, chapterIndex: 1) == nil)
    }
}
