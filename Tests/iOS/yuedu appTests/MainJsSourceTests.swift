import Foundation
import Testing
@testable import yuedu_app

@Suite("mainJs主脚本书源合同", .serialized)
@MainActor
struct MainJsSourceTests {
    nonisolated static let script = #"""
    const config = {bookSourceUrl:"https://mainjs.invalid/#fixture",bookSourceName:"固定主脚本"};
    function search(key,page) { return [{name:key+page,author:"作者",bookUrl:"book-1",variable:{seed:"搜索"}}]; }
    function getChapters(book) { return [{title:"第一章",url:"chapter-1"}]; }
    function getContent(chapter,book,nextChapterUrl) { return "固定正文"; }
    """#

    static func source(script: String = script) throws -> BookSource {
        let data = try JSONSerialization.data(withJSONObject: [
            "bookSourceUrl": "https://mainjs.invalid/#fixture",
            "bookSourceName": "固定主脚本", "mainJs": script
        ])
        return try JSONDecoder().decode(BookSource.self, from: data)
    }

    @Test("单文件JS元数据进入既有导入确认路径")
    func importsSingleFileScript() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MainJsImport-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { do { try FileManager.default.removeItem(at: root) } catch { Issue.record("测试目录清理失败") } }
        let store = BookSourceStore(directory: root); await store.waitUntilLoaded()
        let sources = try await Task.detached {
            try store.parseForImport(data: Data(Self.script.utf8), fileExtension: "js")
        }.value
        let source = try #require(sources.first)
        #expect(sources.count == 1 && source.bookSourceUrl == "https://mainjs.invalid/#fixture")
        #expect(source.bookSourceName == "固定主脚本")
        let json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(source)) as? [String: Any])
        #expect(json["mainJs"] as? String == Self.script)
    }

    @Test("无声明式searchUrl时主脚本生产搜索仍返回对象列表")
    func searchesWithoutDeclarativeURL() async throws {
        let source = try Self.source()
        let books = try await BookSourceSession(source: source).host.searchBooks(keyword: "词", page: 2)
        #expect(books.count == 1)
        let book = try #require(books.first)
        #expect(book.name == "词2" && book.author == "作者" && book.bookUrl == "book-1")
        #expect(book.sourceId == source.id && book.sourceName == source.bookSourceName)
    }

    @Test("生产Fetcher搜索、详情、目录和正文进入原缓存owner")
    func productionPipeline() async throws {
        let script = #"""
        function search(key,page){return [{name:"搜索书名",author:"作者",bookUrl:"https://mainjs.invalid/book",variable:{seed:key}}];}
        function explore(url,page){return search(url,page);}
        function getBookInfo(book){return {name:"不得重命名",intro:book.getVariable("seed"),tocUrl:"https://mainjs.invalid/toc"};}
        function getChapters(book){return [{title:book.name,url:"chapter1",variable:{token:"章节"}},{title:"第二章",url:"chapter2"}];}
        function getContent(chapter,book,nextChapterUrl){return book.name+"|"+chapter.getVariable("token")+"|"+nextChapterUrl;}
        """#
        let source = try Self.source(script: script)
        let fetcher = BookSourceFetcher()
        let search = try await fetcher.searchOutcome(query: "搜索种子", in: source, usesCache: false)
        let book = try #require(search.books.first)
        let info = try await fetcher.fetchBookInfoPackage(url: book.bookUrl, source: source, knownBook: book, usesCache: false)
        #expect(info.name == "搜索书名" && info.intro == "搜索种子")
        let toc = try await fetcher.fetchTOCPackage(tocUrl: info.tocUrl, source: source, runtimeVariables: info.runtimeVariables,
            forceRefresh: true, writesCache: false)
        #expect(toc.chapters.count == 2 && toc.chapters[0].title == "搜索书名")
        let ref = try #require(toc.chapters.first)
        #expect(ref.runtimeVariables?["token"] == "章节")
        let id = UUID()
        defer { fetcher.clearAllChapterCache(bookId: id) }
        let package = try await fetcher.fetchChapterPackage(ref: ref, bookId: id, source: source)
        #expect(package.content.contains("搜索书名|章节|https://mainjs.invalid/chapter2"))
        #expect(fetcher.loadChapterPackageSync(bookId: id, chapterIndex: ref.index)?.content == package.content)
    }

    @Test("元数据导入不暴露java、cache、Cookie和sourceApi")
    func metadataCapabilities() async throws {
        let script = Self.script.replacingOccurrences(of: "固定主脚本", with: "typeof能力") + #"""
        config.bookSourceName=[typeof java,typeof cache,typeof cookie,typeof sourceApi].join("|");
        """#
        let source = try await Task.detached { try MainJsSource.extract(script) }.value
        #expect(source.bookSourceName == "undefined|undefined|undefined|undefined")
        #expect(throws: (any Error).self) {
            try MainJsSource.extract(script)
        }
    }

    @Test("兼容legacy source配置，必需函数与发现配对缺失明确拒绝")
    func configurationValidation() async throws {
        let legacy = Self.script.replacingOccurrences(of: "const config", with: "var source")
        let source = try await Task.detached { try MainJsSource.extract(legacy) }.value
        #expect(source.isJsSource && source.bookSourceName == "固定主脚本")
        let bad = Self.script.replacingOccurrences(of: "function getContent", with: "function absent")
        await #expect(throws: (any Error).self) { try await Task.detached { try MainJsSource.extract(bad) }.value }
        let explore = Self.script + #"config.exploreUrl=[{title:'分类',url:'category'}];"#
        await #expect(throws: (any Error).self) { try await Task.detached { try MainJsSource.extract(explore) }.value }
    }

    @Test("主脚本每次新scope但共享jsLib，toJSON在原执行器归一化")
    func freshScopeAndNormalization() async throws {
        var source = try Self.source(script: #"""
        var local=0;
        function search(key,page){local++;var count=bump();return {toJSON:function(){return [{name:local+":"+count,bookUrl:"opaque"}];}};}
        """#)
        source.jsLib = "var sharedCount=0;function bump(){return ++sharedCount;}"
        let session = BookSourceSession(source: source)
        let first = try await session.host.searchBooks(keyword: "x")
        let second = try await session.host.searchBooks(keyword: "x")
        #expect(first.first?.name == "1:1" && second.first?.name == "1:2")
    }

    @Test("java请求复用现有URLSession和源头部，取消／失效拒绝晚到结果")
    func requestsAndLateResults() async throws {
        let host = "main-js-request-" + UUID().uuidString.lowercased() + ".invalid"
        let events = AsyncStream<URLRequest>.makeStream()
        RSSPageFixtureProtocol.serve(host: host, sequences: ["/search": [.init(body: Data("响应".utf8), held: true)]], events: events.continuation)
        defer { RSSPageFixtureProtocol.remove(host: host) }
        var source = try Self.source(script: "function search(key,page){return [{name:java.ajax('https://" + host + "/search'),bookUrl:'opaque'}];}")
        source.header = #"{"X-Fixture":"main-js"}"#
        let session = BookSourceSession(source: source, requestSession: RSSPageFixtureProtocol.makeSession())
        let task = Task { try await session.host.searchBooks(keyword: "x") }
        var iterator = events.stream.makeAsyncIterator()
        let request = try #require(await iterator.next())
        #expect(request.value(forHTTPHeaderField: "X-Fixture") == "main-js")
        session.invalidate()
        RSSPageFixtureProtocol.release(host: host)
        await #expect(throws: (any Error).self) { try await task.value }
        #expect(RSSPageFixtureProtocol.requests(host: host).count == 1)
    }

    @Test("删源让缓存宿主失效，主脚本变更生成新会话")
    func sourceRevisionInvalidatesSession() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MainJsRevision-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { do { try FileManager.default.removeItem(at: root) } catch { Issue.record("测试目录清理失败") } }
        let store = BookSourceStore(directory: root); await store.waitUntilLoaded()
        let source = try Self.source()
        try store.importSelected([source], options: .direct)
        let original = try #require(store.source(id: source.id))
        let session = BookSourceSession.session(for: original)
        #expect(session.isActive)
        var edited = original; edited.mainJs = "function search(){return [];}"
        store.update(edited)
        #expect(!session.isActive)
        let latest = try #require(store.source(id: source.id))
        let new = BookSourceSession.session(for: latest)
        #expect(new !== session && new.isActive)
        // 缓存只保留32项；被调用方持有的旧宿主仍需在删除时失效。
        for index in 0..<40 {
            _ = BookSourceSession.session(for: BookSource(bookSourceUrl: "https://main-js-eviction.invalid/\(index)", bookSourceName: "临时宿主"))
        }
        _ = store.delete(id: source.id)
        #expect(!new.isActive)
        try await store.persistPendingChanges()
    }

    @Test("文件型主脚本只需搜索和详情，下载项保持顺序并去重")
    func fileSource() async throws {
        let script = #"""
        const config={bookSourceName:"文件源",bookSourceUrl:"https://mainjs-file.invalid",bookSourceType:3};
        function search(){return [{name:"文件书",bookUrl:"https://mainjs-file.invalid/book"}];}
        function getBookInfo(book){return {downloadUrls:["z.txt","a.txt","z.txt","javascript:bad"]};}
        """#
        let source = try await Task.detached { try MainJsSource.extract(script) }.value
        let book = try #require(try await BookSourceSession(source: source).host.searchBooks(keyword: "x").first)
        let info = try await BookSourceFetcher().fetchBookInfoPackage(url: book.bookUrl, source: source, knownBook: book, usesCache: false)
        #expect(info.downloadUrls == ["https://mainjs-file.invalid/z.txt", "https://mainjs-file.invalid/a.txt"])
    }

    @Test("可选详情缺失保留书籍，书与章节变量隔离并支持返回JSON字符串")
    func optionalAndConcurrentScopes() async throws {
        let source = try Self.source(script: #"""
        function search(key){return JSON.stringify([{name:key,bookUrl:key}]);}
        function getChapters(book){book.putVariable('flow',book.name);return [{title:book.name,url:'chapter',variable:{token:book.name}}];}
        function getContent(chapter,book,nextChapterUrl){return chapter.getVariable('token')+'|'+book.getVariable('flow');}
        """#)
        let session = BookSourceSession(source: source)
        let books = try await session.host.searchBooks(keyword: "甲")
        let book = try #require(books.first)
        let info = try await session.parse { try $0.mainJsBookInfo(book: book, canReName: false) }
        #expect(info.name == "甲" && info.bookUrl == "甲" && info.tocUrl == "甲")
        async let a = session.parse { try $0.mainJsChapters(tocURL: "https://mainjs.invalid/a", variables: ["book.name":"甲"]) }
        async let b = session.parse { try $0.mainJsChapters(tocURL: "https://mainjs.invalid/b", variables: ["book.name":"乙"]) }
        let (first, second) = try await (a, b)
        let c1 = try #require(first.first), c2 = try #require(second.first)
        let v1 = try await session.parse { try $0.mainJsContent(chapter: c1, nextChapterURL: nil) }
        let v2 = try await session.parse { try $0.mainJsContent(chapter: c2, nextChapterURL: nil) }
        #expect(v1 == "甲|甲" && v2 == "乙|乙")
    }

    @Test("真正取消在途主脚本请求不返回晚到书籍")
    func cancellation() async throws {
        let host = "main-js-cancel-" + UUID().uuidString.lowercased() + ".invalid"
        let events = AsyncStream<URLRequest>.makeStream()
        RSSPageFixtureProtocol.serve(host: host, sequences: ["/search": [.init(body: Data("响应".utf8), held: true)]], events: events.continuation)
        defer { RSSPageFixtureProtocol.remove(host: host) }
        let source = try Self.source(script: "function search(){return [{name:java.ajax('https://" + host + "/search'),bookUrl:'opaque'}];}")
        let session = BookSourceSession(source: source, requestSession: RSSPageFixtureProtocol.makeSession())
        let task = Task { try await session.host.searchBooks(keyword: "x") }
        var iterator = events.stream.makeAsyncIterator()
        _ = try #require(await iterator.next())
        task.cancel()
        RSSPageFixtureProtocol.release(host: host)
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test("返回值循环引用和序列化超时明确失败，同一宿主可继续使用")
    func serializationFailures() async throws {
        let circular = try Self.source(script: "function search(){var x={};x.self=x;return x;}")
        await #expect(throws: (any Error).self) { try await BookSourceSession(source: circular).host.searchBooks(keyword: "x") }
        let source = try Self.source(script: #"""
        function search(key){if(key==='slow')return {toJSON:function(){var stop=Date.now()+350;while(Date.now()<stop){};return [];}};return [];}
        """#)
        let state = BookSourceRuntimeStateStore(sharedSuiteName: "MainJsTimeout-" + UUID().uuidString)
        let overrides = SourceRuntimeOverrides(identity: UUID().uuidString, authenticationKey: source.bookSourceUrl,
            propertiesJSON: try JSONEncoder().encode(source), state: state, scriptTimeout: 0.08)
        let session = BookSourceSession(source: source, runtimeOverrides: overrides)
        await #expect(throws: ModernParserBridgeError.self) { try await session.host.searchBooks(keyword: "slow") }
        #expect(try await session.host.searchBooks(keyword: "fast").isEmpty)
    }

    @Test("JSON主脚本保真且更新不变不写，jsLib不能误判为主脚本")
    func jsonRoundTripAndNoOp() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MainJsJSON-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { do { try FileManager.default.removeItem(at: root) } catch { Issue.record("测试目录清理失败") } }
        let store = BookSourceStore(directory: root); await store.waitUntilLoaded()
        let source = try Self.source()
        try store.importSelected([source], options: .direct); try await store.persistPendingChanges()
        let revision = store.mutationRevision
        try store.importSelected([source], options: .direct); try await store.persistPendingChanges()
        #expect(store.mutationRevision == revision)
        let loaded = BookSourceStore(directory: root); await loaded.waitUntilLoaded()
        #expect(loaded.source(id: source.id)?.mainJs == Self.script)
        var plain = BookSource(); plain.jsLib = Self.script
        #expect(!plain.isJsSource)
    }

    @Test("章节丢弃无效条目后连续编号，卷占位与可读卷分开")
    func chapterContracts() async throws {
        let source = try Self.source(script: #"""
        function getChapters(book){return [null,{title:'无URL'},{title:'卷一',url:'卷一',isVolume:true},
            {title:'可读卷',url:'/v1',isVolume:true,isVip:true,isPay:true},{title:'章节',url:'/c1'}];}
        function getContent(chapter,book){return chapter.title+'|'+book.totalChapterNum;}
        """#)
        let session = BookSourceSession(source: source)
        let chapters = try await session.parse { try $0.mainJsChapters(tocURL: "https://mainjs.invalid/toc") }
        #expect(chapters.count == 3 && chapters.map(\.index) == [0,1,2])
        #expect(chapters[0].url == "卷一" && chapters[0].shouldRenderAsVolumeSeparator)
        #expect(chapters[1].isVolume && !chapters[1].shouldRenderAsVolumeSeparator && chapters[1].isVip && chapters[1].isPay)
        #expect(try await session.parse { try $0.mainJsContent(chapter: chapters[0], nextChapterURL: nil) } == "")
        #expect(try await session.parse { try $0.mainJsContent(chapter: chapters[1], nextChapterURL: nil) } == "可读卷|3")
    }

    @Test("主脚本返回书籍类型不与书源分类数字混用")
    func bookTypeDomain() async throws {
        let source = try Self.source(script: "function search(){return [{name:'音频',bookUrl:'a',type:32},{name:'图片',bookUrl:'b',type:64},{name:'文字',bookUrl:'c',type:8}];}")
        let books = try await BookSourceSession(source: source).host.searchBooks(keyword: "x")
        #expect(books[0].inferredContentKind(source: source) == .audio)
        #expect(books[1].inferredContentKind(source: source) == .manga)
        #expect(books[2].inferredContentKind(source: source) == .text)
    }

    @Test("人工离线fixture实际导入并读取目录与正文，不依赖公网")
    func offlineFixture() async throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Fixtures/main-js/offline-demo.js")
        let source = try await SourceScriptThread.run { try MainJsSource.extract(String(contentsOf: url, encoding: .utf8)) }
        let fetcher = BookSourceFetcher()
        let book = try #require(try await fetcher.searchOutcome(query: "验收词", in: source, usesCache: false).books.first)
        let info = try await fetcher.fetchBookInfoPackage(url: book.bookUrl, source: source, knownBook: book, usesCache: false)
        let toc = try await fetcher.fetchTOCPackage(tocUrl: info.tocUrl, source: source, runtimeVariables: info.runtimeVariables,
            forceRefresh: true, writesCache: false)
        #expect(toc.chapters.count == 3 && toc.chapters[0].shouldRenderAsVolumeSeparator)
        let chapter = toc.chapters[1], id = UUID()
        defer { fetcher.clearAllChapterCache(bookId: id) }
        let content = try await fetcher.fetchChapterPackage(ref: chapter, bookId: id, source: source).content
        #expect(content.contains("第一章变量") && content.contains("目录总数：3"))
        #expect(content.contains("https://mainjs-demo.invalid/chapter2"))
    }

    @Test("缺函数、异常和非数组不伪装成合法空搜索")
    func errorsAreNotEmpty() async throws {
        for script in ["function absent(){}", "function search(){throw Error('失败');}", "function search(){return {};}"] {
            let source = try Self.source(script: script)
            await #expect(throws: (any Error).self) { try await BookSourceSession(source: source).host.searchBooks(keyword: "x") }
        }
        let empty = try Self.source(script: "function search(){return null;}")
        #expect(try await BookSourceSession(source: empty).host.searchBooks(keyword: "x").isEmpty)
    }
}
