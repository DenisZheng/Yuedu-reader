import Foundation
import Testing
@testable import yuedu_app

@Suite("副文固定输入合同", .serialized)
@MainActor
struct SourceSubContentTests {
    static func source(type: Int = 0, rule: String = ".extra@text") throws -> BookSource {
        let json: [String: Any] = ["bookSourceUrl": "https://sub-content.invalid", "bookSourceName": "自建副文源",
            "bookSourceType": type, "ruleContent": ["content": ".body@text", "subContent": rule]]
        return try JSONDecoder().decode(BookSource.self, from: JSONSerialization.data(withJSONObject: json))
    }

    @Test("文本副文取原页面且在整章替换前追加")
    func textAppendedBeforeReplacement() async throws {
        var source = try Self.source()
        source.ruleContent.replaceRegex = "##旧##新"
        let parsed = try await BookSourceSession(source: source).parse { bridge in
            try bridge.parseChapterResult(html: "<p class=body>旧正文</p><p class=extra>旧副文</p>",
                baseURL: source.bookSourceUrl, source: source)
        }
        #expect(parsed.content.contains("新正文"))
        #expect(parsed.content.contains("新副文"))
        if let main = parsed.content.range(of: "新正文"), let extra = parsed.content.range(of: "新副文") {
            #expect(main.lowerBound < extra.lowerBound)
        }
    }

    @Test("ContentRule自身承载副文而非仅保留未知字段")
    func executableField() throws {
        let rule = try JSONDecoder().decode(ContentRule.self, from: Data(#"{"subContent":".extra@text"}"#.utf8))
        let object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(rule)) as? [String: Any])
        #expect(object["subContent"] as? String == ".extra@text")
    }

    @Test("文本URL只是副文文本；图像源不解释副文；空规则不追加")
    func typeBoundaries() async throws {
        for type in [0, 2] {
            let source = try Self.source(type: type)
            let parsed = try await BookSourceSession(source: source).parse {
                try $0.parseChapterResult(html: "<p class=body>正文</p><p class=extra>https://never-request.invalid/extra</p>",
                    baseURL: source.bookSourceUrl, source: source)
            }
            #expect(parsed.content.contains("never-request") == (type == 0))
            #expect(parsed.subContent == nil)
        }
        let source = try Self.source(rule: "")
        let parsed = try await BookSourceSession(source: source).parse {
            try $0.parseChapterResult(html: "<p class=body>正文</p><p class=extra>不追加</p>", baseURL: source.bookSourceUrl, source: source)
        }
        #expect(parsed.content == "正文")
    }

    @Test("生产下载、重新加载artifact与媒体地址分离，缓存命中不重取副文")
    func mediaDownloadReloadAndCache() async throws {
        for type in [1, 4] {
            let host = "sub-content-" + UUID().uuidString.lowercased() + ".invalid"
            let url = "https://" + host
            let extra = type == 1 ? "[00:01.00]自建歌词" : "<i><d p=\"1,1,25,16777215\">自建弹幕</d></i>"
            RSSPageFixtureProtocol.serve(host: host, sequences: [
                "/chapter": [.init(body: Data("<p class=body>https://media.invalid/play</p><p class=extra>\(url)/extra</p>".utf8))],
                "/extra": [.init(body: Data(extra.utf8))]
            ])
            defer { RSSPageFixtureProtocol.remove(host: host) }
            var source = try Self.source(type: type); source.bookSourceUrl = url
            let id = UUID(), fetcher = BookSourceFetcher(), ref = OnlineChapterRef(index: 3, title: "媒体章节", url: url + "/chapter,{}")
            _ = BookSourceSession.session(for: source, requestSession: RSSPageFixtureProtocol.makeSession())
            defer { fetcher.clearAllChapterCache(bookId: id) }
            let package = try await fetcher.fetchChapterPackage(ref: ref, bookId: id, source: source)
            #expect(package.content.contains("https://media.invalid/play"))
            #expect(!package.content.contains("自建"))
            #expect(package.subContent?.kind == (type == 1 ? .lyric : .danmaku))
            #expect(package.subContent?.text == extra)
            #expect(package.subContent?.failure == nil)
            let again = try await fetcher.fetchChapterPackage(ref: ref, bookId: id, source: source)
            #expect(again == package)
            #expect(RSSPageFixtureProtocol.requests(host: host).count == 2)
            let reread = try #require(fetcher.loadChapterPackageSync(bookId: id, chapterIndex: 3))
            #expect(reread.subContent == package.subContent)
        }
    }

    @Test("副文HTTP失败和字节上限保留主内容及明确分型失败")
    func supplementalFailures() async throws {
        for mode in ["status", "budget", "inline", "script"] {
            let host = "sub-failure-" + UUID().uuidString.lowercased() + ".invalid", url = "https://" + host
            var source = try Self.source(type: 1, rule: mode == "script" ? "@js:throw Error('private');" : ".extra@text")
            source.bookSourceUrl = url
            let value = mode == "inline" ? String(repeating: "x", count: ChapterSubContent.maximumBytes + 1) : url + "/extra"
            RSSPageFixtureProtocol.serve(host: host, sequences: [
                "/extra": [.init(body: Data(repeating: 65, count: mode == "budget" ? ChapterSubContent.maximumBytes + 1 : 20), status: mode == "status" ? 503 : 200)]
            ])
            defer { RSSPageFixtureProtocol.remove(host: host) }
            let stable = source
            let session = BookSourceSession(source: stable, requestSession: RSSPageFixtureProtocol.makeSession())
            let parsed = try await session.operation { host in
                try await host.parseChapterPage(html: "<p class=body>https://media.invalid/play</p><p class=extra>\(value)</p>", baseURL: url, source: stable)
            }
            #expect(parsed.content == "https://media.invalid/play")
            #expect(parsed.subContent?.text == "")
            #expect(parsed.subContent?.failure == (mode == "script" ? .rule : mode == "status" ? .request : .budget))
            #expect(parsed.subContentRequest == nil)
            #expect(RSSPageFixtureProtocol.requests(host: host).count == (["inline", "script"].contains(mode) ? 0 : 1))
        }
    }

    @Test("分页副文按章覆盖；正文按页追加；旧artifact向后兼容")
    func paginationAndLegacy() throws {
        var first = ChapterParsePayload(content: "第一", title: "章节", sourceMatched: true, isPay: false,
            subContent: ChapterSubContent(kind: .lyric, text: "首份"))
        let next = ChapterParsePayload(content: "第二", title: "", sourceMatched: true, isPay: false,
            subContent: ChapterSubContent(kind: .lyric, text: "末份"))
        first = ChapterFetcher.shared.merge(first, next)
        #expect(first.content == "第一\n第二" && first.subContent?.text == "末份")
        let legacy = #"{"contentChecksum":"checksum","savedAt":0}"#
        #expect(try JSONDecoder().decode(ChapterPackageArtifact.self, from: Data(legacy.utf8)).subContent == nil)
    }

    @Test("相同正文但副文更改必须保存；重复完整内容不写；清除使旧写失效")
    func cacheOwnershipAndNoOp() async throws {
        let root = try SourceContentBatchTests.root(); defer { SourceContentBatchTests.cleanup(root) }
        try await Task.detached {
            let repo = ChapterCacheRepository(rootDirectory: root), id = UUID()
            try repo.saveToCache(content: "https://media.invalid/play", bookId: id, chapterIndex: 0)
            var package = try #require(repo.loadChapterPackageSync(bookId: id, chapterIndex: 0))
            package.subContent = ChapterSubContent(kind: .lyric, text: "新歌词")
            let ticket = repo.beginWrite(bookId: id, chapterIndex: 0)
            defer { repo.finishWrite(ticket) }
            try repo.saveChapterPackageToCache(package, rawHTML: nil, normalizedHTML: nil, writeTicket: ticket)
            #expect(repo.loadChapterPackageSync(bookId: id, chapterIndex: 0)?.subContent?.text == "新歌词")
            let files = try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent(id.uuidString), includingPropertiesForKeys: [.contentModificationDateKey])
            let dates = try files.map { try $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate }
            try repo.saveChapterPackageToCache(package, rawHTML: nil, normalizedHTML: nil, writeTicket: ticket)
            #expect(try files.map { try $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate } == dates)
            repo.clearAllChapterCache(bookId: id)
            #expect(throws: ChapterCacheWriteError.staleWrite) {
                try repo.saveChapterPackageToCache(package, rawHTML: nil, normalizedHTML: nil, writeTicket: ticket)
            }
            #expect(repo.loadChapterPackageSync(bookId: id, chapterIndex: 0) == nil)
        }.value
    }

    @Test("原生chapter歌词写回桥不丢失到正文或下一章")
    func explicitChapterMediaBridge() async throws {
        var source = SourceContentBatchTests.source()
        source.bookSourceType = 1
        source.mainJs = "function getContent(c){c.putLyric('[00:01.00]歌词'+c.index);return 'https://media.invalid/'+c.index;}"
        let fetcher = BookSourceFetcher(), id = UUID()
        defer { fetcher.clearAllChapterCache(bookId: id) }
        for index in [0,1] {
            let package = try await fetcher.fetchChapterPackage(ref: .init(index: index, title: "章", url: "https://sub-media.invalid/\(index)"), bookId: id, source: source)
            #expect(package.content.contains("https://media.invalid/\(index)"))
            #expect(package.subContent?.text == "[00:01.00]歌词\(index)")
        }
    }

    @Test("两种批量源只回存脚本主动写出的分型副文，不重新执行副文规则")
    func explicitBatchSubContent() async throws {
        let root = try SourceContentBatchTests.root(); defer { SourceContentBatchTests.cleanup(root) }
        for main in [true, false] {
            var source = SourceContentBatchTests.source(mainJs: main, batch: "chapters.forEach(function(c){c.putDanmaku('<i><d p=\"1,1\">弹幕'+c.index+'</d></i>');java.cacheContent(c,'https://media.invalid/'+c.index);});")
            source.bookSourceType = 4
            source.ruleContent.subContent = "@js:throw Error('batch must not execute subContent');"
            let repo = ChapterCacheRepository(rootDirectory: root), id = UUID()
            #expect(try await BookSourceFetcher().fetchContentBatch(refs: SourceContentBatchTests.refs(), bookId: id, source: source, repository: repo).isEmpty)
            for index in 0..<3 {
                let package = try #require(repo.loadChapterPackageSync(bookId: id, chapterIndex: index))
                #expect(package.content == "https://media.invalid/\(index)")
                #expect(package.subContent?.kind == .danmaku)
                #expect(package.subContent?.text.contains("弹幕\(index)") == true)
            }
        }
    }

    @Test("LRC多时间、XML弹幕、非法输入和外部实体都有明确结果")
    func timedDocuments() async throws {
        try await Task.detached {
            let lyric = try ChapterSubContentDocument.parse(.init(kind: .lyric, text: "[00:03.50][00:01.20]歌词\n纯文字"))
            #expect(lyric.cues.count == 3)
            #expect(lyric.cues.compactMap(\.seconds) == [1.2,3.5])
            let danmaku = try ChapterSubContentDocument.parse(.init(kind: .danmaku, text: "<i><d p=\"2.5,1,25,1\">弹幕&amp;文字</d></i>"))
            #expect(danmaku.cues.first?.seconds == 2.5 && danmaku.cues.first?.text == "弹幕&文字")
            for xml in ["<i><d p=\"NaN,1\">坏值</d></i>", "<!DOCTYPE i SYSTEM 'https://never-request.invalid'><i/>", "[]", "<i><d>"] {
                #expect(throws: SourceSubContentError.format) { try ChapterSubContentDocument.parse(.init(kind: .danmaku, text: xml)) }
            }
            #expect(try ChapterSubContentDocument.parse(.init(kind: .lyric, text: "")).cues.isEmpty)
        }.value
    }

    @Test("副文跨域不继承私有源头，但保留源显式目标头")
    func scopedSupplementalAuthentication() async throws {
        let own = "sub-origin-" + UUID().uuidString.lowercased() + ".invalid"
        let cdn = "sub-cdn-" + UUID().uuidString.lowercased() + ".invalid"
        RSSPageFixtureProtocol.serve(host: cdn, contentType: "text/plain", body: Data("[00:01]源副文".utf8))
        defer { RSSPageFixtureProtocol.remove(host: cdn) }
        var source = try Self.source(type: 1)
        source.bookSourceUrl = "https://" + own
        source.header = #"{"X-Source-Private":"self-authored-secret","User-Agent":"SourceTest"}"#
        let stable = source
        let session = BookSourceSession(source: stable, requestSession: RSSPageFixtureProtocol.makeSession())
        let parsed = try await session.operation { host in
            try await host.parseChapterPage(html: "<p class=body>https://media.invalid/play</p><p class=extra>https://\(cdn)/extra</p>", baseURL: "https://"+own, source: stable)
        }
        #expect(parsed.subContent?.failure == nil)
        let request = try #require(RSSPageFixtureProtocol.requests(host: cdn).first)
        #expect(request.value(forHTTPHeaderField: "X-Source-Private") == nil)
        #expect(request.value(forHTTPHeaderField: "User-Agent") == "SourceTest")
    }

    @Test("同源副文等待期间URL脚本交错，取回后仍恢复原章上下文")
    func supplementalResponseKeepsChapterScope() async throws {
        let hostName = "sub-interleave-" + UUID().uuidString.lowercased() + ".invalid", url = "https://" + hostName
        let events = AsyncStream<URLRequest>.makeStream()
        RSSPageFixtureProtocol.serve(host: hostName, sequences: [
            "/extra": [.init(body: Data("副文".utf8), held: true)], "/other": [.init(body: Data("另一请求".utf8))]
        ], events: events.continuation)
        defer { RSSPageFixtureProtocol.remove(host: hostName) }
        var source = try Self.source(type: 1)
        source.bookSourceUrl = url
        let options = String(decoding: try JSONSerialization.data(withJSONObject: ["bodyJs":"result+'|'+chapter.index"]), as: UTF8.self)
        let stable = source, session = BookSourceSession(source: source, requestSession: RSSPageFixtureProtocol.makeSession())
        let task = Task { try await session.operation { host in
            try await host.parseChapterPage(html: "<p class=body>https://media.invalid/play</p><p class=extra>\(url)/extra,\(options)</p>",
                baseURL: url, source: stable, chapterRef: .init(index: 3, title: "原章", url: url+"/chapter"))
        } }
        var iterator = events.stream.makeAsyncIterator()
        _ = try #require(await iterator.next())
        _ = try await session.host.fetch(ruleUrl: "@js:chapter.index=9;'\(url)/other';")
        RSSPageFixtureProtocol.release(host: hostName)
        let result = try await task.value
        #expect(result.subContent?.text == "副文|3")
    }

    @Test("真实副文请求后取消、清缓存、删源均不得晚到写回")
    func lateSubContentCannotReviveCache() async throws {
        for mode in ["cancel", "clear", "invalidate"] {
            let host = "sub-held-" + UUID().uuidString.lowercased() + ".invalid", url = "https://" + host
            let events = AsyncStream<URLRequest>.makeStream()
            RSSPageFixtureProtocol.serve(host: host, sequences: [
                "/chapter": [.init(body: Data("<p class=body>https://media.invalid/play</p><p class=extra>\(url)/extra</p>".utf8))],
                "/extra": [.init(body: Data("[00:00]旧歌词".utf8), held: true)]
            ], events: events.continuation)
            defer { RSSPageFixtureProtocol.remove(host: host) }
            var source = try Self.source(type: 1); source.bookSourceUrl = url
            let stable = source, id = UUID(), fetcher = BookSourceFetcher(), ref = OnlineChapterRef(index: 0, title: "章", url: url + "/chapter,{}")
            _ = BookSourceSession.session(for: stable, requestSession: RSSPageFixtureProtocol.makeSession())
            defer { fetcher.clearAllChapterCache(bookId: id) }
            let task = Task { try await fetcher.fetchChapterPackage(ref: ref, bookId: id, source: stable) }
            var iterator = events.stream.makeAsyncIterator()
            while let event = await iterator.next() { if event.url?.path == "/extra" { break } }
            if mode == "cancel" { task.cancel() }
            else if mode == "clear" { fetcher.clearAllChapterCache(bookId: id) }
            else { BookSourceSession.session(for: source).invalidate() }
            RSSPageFixtureProtocol.release(host: host)
            await #expect(throws: (any Error).self) { try await task.value }
            #expect(fetcher.loadChapterPackageSync(bookId: id, chapterIndex: 0) == nil)
        }
    }
}
