import Foundation
import Testing
import os
@testable import yuedu_app

/// S7：分类、版本化 WebDAV 备份与历史恢复的故障注入。走真实 WebDAVManager 请求构造，
/// 服务端为内存 URLProtocol；本机数据为隔离实现，不碰真实书库。
@Suite("S7 WebDAV versioned backup", .serialized)
@MainActor struct WebDAVVersionedBackupTests {
    final class FakeLocal: WebDAVBackupLocalData, @unchecked Sendable {
        let lock = NSLock()
        var data: [WebDAVBackupCategory: Data]
        var applied: [[WebDAVBackupCategory]] = []
        var space: Int64 = .max
        var rejects: Set<WebDAVBackupCategory> = []
        init(_ data: [WebDAVBackupCategory: Data]) { self.data = data }
        func export(_ category: WebDAVBackupCategory) async throws -> Data? { lock.withLock { data[category] } }
        func validate(_ category: WebDAVBackupCategory, _ data: Data) async throws {
            if lock.withLock({ rejects.contains(category) }) { throw WebDAVBackupError.corrupt(category) }
        }
        func apply(_ staged: [(WebDAVBackupCategory, Data)]) async throws {
            lock.withLock { applied.append(staged.map(\.0)); for (k, v) in staged { data[k] = v } }
        }
        func availableBytes() throws -> Int64 { lock.withLock { space } }
    }

    @Test("两个版本独立保存、新到旧列出；只还原所选分类；manifest最后写入")
    func versionsAndSubsetRestore() async throws {
        try await withManager { manager in
            let local = FakeLocal([.bookSources: Data("[1]".utf8), .rss: Data("rss-1".utf8)])
            let first = try await manager.backupVersion(categories: [.bookSources, .rss, .bookshelf], local: local, now: Date(timeIntervalSince1970: 1_000))
            #expect(first.files.map(\.category) == [.bookSources, .rss], "本机没有数据的分类不上传")
            local.data[.bookSources] = Data("[2]".utf8)
            let second = try await manager.backupVersion(categories: [.bookSources], local: local, now: Date(timeIntervalSince1970: 2_000))
            let listed = try await manager.listBackupVersions().map(\.name)
            #expect(listed == [second.name, first.name])
            let puts = WebDAVMemory.state.withLock { $0.log.filter { $0.hasPrefix("PUT") } }
            #expect(puts.last == "PUT " + WebDAVBackupLayout.root + second.name + "/manifest.json")

            local.data[.bookSources] = Data("[local]".utf8); local.data[.rss] = Data("rss-local".utf8)
            let restored = try await manager.restoreVersion(first.name, categories: [.bookSources], local: local)
            #expect(restored == [.bookSources])
            #expect(local.data[.bookSources] == Data("[1]".utf8))
            #expect(local.data[.rss] == Data("rss-local".utf8), "未选分类不改动")
        }
    }

    @Test("上传中断（manifest未写）的版本不列出、不能恢复；越界名字被拒绝")
    func interruptedAndTraversal() async throws {
        try await withManager { manager in
            let local = FakeLocal([.replaceRules: Data("[]".utf8)])
            WebDAVMemory.state.withLock { $0.failPUTSuffix = "manifest.json" }
            await #expect(throws: WebDAVError.self) {
                _ = try await manager.backupVersion(categories: [.replaceRules], local: local, now: Date(timeIntervalSince1970: 3_000))
            }
            WebDAVMemory.state.withLock { $0.failPUTSuffix = nil }
            let visible = try await manager.listBackupVersions()
            #expect(visible.isEmpty, "无manifest的残缺目录不可见")
            let partialPath = try #require(WebDAVMemory.state.withLock { $0.collections.filter { $0.hasPrefix(WebDAVBackupLayout.root) && $0 != WebDAVBackupLayout.root }.first })
            let partial = try #require(partialPath.split(separator: "/").last.map(String.init))
            do {
                _ = try await manager.restoreVersion(partial, categories: [.replaceRules], local: local)
                Issue.record("残缺版本不应可恢复")
            } catch {
                guard case WebDAVError.fileNotFound = error else { Issue.record("意外错误：\(error)"); return }
            }
            #expect(local.applied.isEmpty)
            await #expect(throws: WebDAVBackupError.invalidName) { _ = try await manager.backupManifest("../../yuedu") }
            let listing = Data("""
            <d:multistatus xmlns:d="DAV:"><d:response><d:href>/readerfork-dev/backups/</d:href></d:response>
            <d:response><d:href>/readerfork-dev/backups/..%2F..%2Fyuedu/</d:href></d:response>
            <d:response><d:href>https://dav.invalid/readerfork-dev/backups/20260101T000000Z-0123abcd-123456/</d:href></d:response></d:multistatus>
            """.utf8)
            #expect(try WebDAVBackupLayout.names(fromListing: listing) == ["20260101T000000Z-0123abcd-123456"])
            #expect(throws: WebDAVBackupError.corrupt(nil)) { try WebDAVBackupLayout.names(fromListing: Data("<broken>".utf8)) }
            let sameTimeA = WebDAVBackupLayout.name(date: Date(timeIntervalSince1970: 3000), deviceID: "12345678", nonce: "abcdef")
            let sameTimeB = WebDAVBackupLayout.name(date: Date(timeIntervalSince1970: 3000), deviceID: "12345678", nonce: "123456")
            #expect(sameTimeA != sameTimeB && WebDAVBackupLayout.isValid(sameTimeA))
        }
    }

    @Test("校验和不符、内容校验失败、空间不足、较新格式、取消：都不修改本机")
    func failuresDoNotTouchLocal() async throws {
        try await withManager { manager in
            let local = FakeLocal([.bookSources: Data("[1]".utf8), .rss: Data("rss".utf8)])
            let version = try await manager.backupVersion(categories: [.bookSources, .rss], local: local, now: Date(timeIntervalSince1970: 4_000))
            let dir = WebDAVBackupLayout.root + version.name + "/"

            WebDAVMemory.state.withLock { $0.files[dir + "rss.json"] = Data("tampered".utf8) }
            await #expect(throws: WebDAVBackupError.corrupt(.rss)) {
                _ = try await manager.restoreVersion(version.name, categories: [.bookSources, .rss], local: local)
            }
            WebDAVMemory.state.withLock { $0.files[dir + "rss.json"] = Data("rss".utf8) }

            local.rejects = [.bookSources]
            await #expect(throws: WebDAVBackupError.corrupt(.bookSources)) {
                _ = try await manager.restoreVersion(version.name, categories: [.bookSources], local: local)
            }
            local.rejects = []

            local.space = 10
            await #expect(throws: WebDAVBackupError.insufficientSpace) {
                _ = try await manager.restoreVersion(version.name, categories: [.rss], local: local)
            }
            local.space = .max

            var manifest = try await manager.backupManifest(version.name)
            manifest.format = WebDAVBackupManifest.currentFormat + 1
            let newer = try WebDAVBackupLayout.encodeManifest(manifest)
            WebDAVMemory.state.withLock { $0.files[dir + "manifest.json"] = newer }
            await #expect(throws: WebDAVBackupError.unsupportedFormat) {
                _ = try await manager.restoreVersion(version.name, categories: [.rss], local: local)
            }
            manifest.format = WebDAVBackupManifest.currentFormat; manifest.name = "20000101T000000Z-00000000"
            let renamed = try WebDAVBackupLayout.encodeManifest(manifest)
            WebDAVMemory.state.withLock { $0.files[dir + "manifest.json"] = renamed }
            await #expect(throws: WebDAVBackupError.corrupt(nil)) {
                _ = try await manager.restoreVersion(version.name, categories: [.rss], local: local)
            }

            let task = Task { try await manager.restoreVersion(version.name, categories: [.rss], local: local) }
            task.cancel()
            switch await task.result {
            case .failure(let error): #expect(error is CancellationError)
            case .success: Issue.record("取消不应成功")
            }
            #expect(local.applied.isEmpty, "任何失败或取消都不能进入写入阶段")
        }
    }

    @Test("生产写入中途失败：已写分类回滚到原字节，不留半套数据")
    func productionApplyRollsBack() async throws {
        let directory = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { do { try FileManager.default.removeItem(at: directory) } catch { Issue.record(error) } }
        let sources = directory.appendingPathComponent("book_sources.json")
        try Data("[\"old\"]".utf8).write(to: sources)
        let local = WebDAVProductionLocalData(rss: RSSStore(storageDirectory: directory.appendingPathComponent("rss")), bookStore: nil,
            fileOverrides: [.bookSources: sources,
                            .replaceRules: directory.appendingPathComponent("missing/dir/replace_rules.json")],
            recoveryDirectory: directory.appendingPathComponent("recovery"))
        await #expect(throws: (any Error).self) {
            try await local.apply([(.bookSources, Data("[]".utf8)), (.replaceRules, Data("[]".utf8))])
        }
        #expect(try Data(contentsOf: sources) == Data("[\"old\"]".utf8))
        await #expect(throws: WebDAVBackupError.corrupt(.bookSources)) { try await local.validate(.bookSources, Data("{".utf8)) }
        await #expect(throws: WebDAVBackupError.corrupt(.rss)) { try await local.validate(.rss, Data("{}".utf8)) }
    }

    @Test("普通分类写入先失败不能损坏尚未恢复的RSS正文、链接或变量")
    func failedFileRestoreLeavesRSSIntact() async throws {
        let directory = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { do { try FileManager.default.removeItem(at: directory) } catch { Issue.record(error) } }
        let rss = RSSStore(storageDirectory: directory.appendingPathComponent("rss"))
        let source = RSSSource(name: "Preserve", url: "https://preserve.invalid/rss")
        rss.addSource(source)
        let item = RSSItem(id: "preserve", title: "Original", link: "https://preserve.invalid/article", contentHTML: "<p>Full body</p>", sourceId: source.id)
        rss.mergeFetchedItems([item], for: source.id)
        rss.setVariables(["private": "fixture-value"], for: source.id)
        let before = try #require(rss.article(id: item.id))
        let data = try await rss.backupData()
        let local = WebDAVProductionLocalData(rss: rss, bookStore: nil,
            fileOverrides: [.replaceRules: directory.appendingPathComponent("missing/rules.json")],
            recoveryDirectory: directory.appendingPathComponent("recovery"))
        await #expect(throws: (any Error).self) {
            try await local.apply([(.replaceRules, Data("[]".utf8)), (.rss, data)])
        }
        #expect(rss.article(id: item.id) == before)
        #expect(rss.variables(for: source.id) == ["private": "fixture-value"])
        try await rss.flushPersistence()
        let reloaded = RSSStore(storageDirectory: directory.appendingPathComponent("rss"))
        #expect(reloaded.article(id: item.id) == before)
    }

    @Test("RSS落盘中途失败：恢复原正文、运行变量与阅读状态，并回滚其他分类")
    func rssWriteFailureRollsBackFullLocalState() async throws {
        let directory = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { do { try FileManager.default.removeItem(at: directory) } catch { Issue.record(error) } }
        let rssDirectory = directory.appendingPathComponent("rss")
        let owner = RSSStore(storageDirectory: rssDirectory)
        let source = RSSSource(name: "Full state", url: "https://full.invalid/rss")
        owner.addSource(source)
        let item = RSSItem(id: "full", title: "Original", link: "https://full.invalid/a", contentHTML: "<p>full body</p>", sourceId: source.id)
        owner.mergeFetchedItems([item], for: source.id)
        owner.setVariables(["saved": "fixture"], for: source.id)
        owner.toggleFavorite(articleId: item.id)
        let before = try #require(owner.article(id: item.id))
        let cloud = try await owner.backupData()
        let once = OSAllocatedUnfairLock(initialState: false)
        owner.persistenceWriteFailure = { name in
            guard name == "rss_article_status.json" else { return false }
            return once.withLock { failed in
                guard !failed else { return false }
                failed = true
                return true
            }
        }
        let bookFile = directory.appendingPathComponent("book_sources.json")
        let originalBooks = Data("[\"original bytes\"]".utf8)
        try originalBooks.write(to: bookFile)
        let local = WebDAVProductionLocalData(rss: owner, bookStore: nil,
            fileOverrides: [.bookSources: bookFile], recoveryDirectory: directory.appendingPathComponent("recovery"))
        await #expect(throws: RSSImportService.Issue.self) {
            try await local.apply([(.bookSources, Data("[]".utf8)), (.rss, cloud)])
        }
        #expect(once.withLock { $0 }, "必须真的经过落盘故障")
        #expect(owner.article(id: item.id) == before)
        #expect(owner.variables(for: source.id) == ["saved": "fixture"])
        #expect(try Data(contentsOf: bookFile) == originalBooks)
        try await owner.flushPersistence()
        let reloaded = RSSStore(storageDirectory: rssDirectory)
        #expect(reloaded.article(id: item.id) == before)
        #expect(reloaded.variables(for: source.id) == ["saved": "fixture"])
    }

    private func withManager(_ run: (WebDAVManager) async throws -> Void) async throws {
        let name = "WebDAVVersioned-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [WebDAVMemory.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        WebDAVMemory.state.withLock { $0 = .init() }
        let manager = WebDAVManager(defaults: defaults, session: session)
        manager.serverUrl = "https://dav.invalid"
        manager.username = "synthetic"; manager.password = "synthetic"
        try await run(manager)
    }
}

/// 内存 WebDAV：MKCOL/PUT/GET/PROPFIND(Depth 1)；只认 dav.invalid。
private final class WebDAVMemory: URLProtocol {
    struct State {
        var files: [String: Data] = [:]
        var collections: Set<String> = []
        var log: [String] = []
        var failPUTSuffix: String?
    }
    static let state = OSAllocatedUnfairLock(initialState: State())
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "dav.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        guard let url = request.url else { client?.urlProtocol(self, didFailWithError: URLError(.badURL)); return }
        let method = request.httpMethod ?? "GET"
        var raw = url.absoluteString
        raw = String(raw.dropFirst("https://dav.invalid".count))
        let path = raw.components(separatedBy: "?")[0]
        let body = request.httpBody ?? Self.read(request.httpBodyStream)
        let (status, output): (Int, Data) = Self.state.withLock { state in
            state.log.append("\(method) \(path)")
            switch method {
            case "MKCOL":
                if state.collections.contains(path) { return (405, Data()) }
                state.collections.insert(path); return (201, Data())
            case "PUT":
                if let suffix = state.failPUTSuffix, path.hasSuffix(suffix) { return (507, Data()) }
                state.files[path] = body; return (201, Data())
            case "GET":
                guard let data = state.files[path] else { return (404, Data()) }
                return (200, data)
            case "PROPFIND":
                guard state.collections.contains(path) else { return (404, Data()) }
                let children = state.collections.filter { $0 != path && $0.hasPrefix(path) && !$0.dropFirst(path.count).dropLast().contains("/") }
                // 只有 manifest 存在的目录才算完整版本；目录本身照常列出，由客户端再取 manifest。
                let entries = ([path] + children.sorted()).map { "<d:response><d:href>\($0)</d:href></d:response>" }.joined()
                return (207, Data("<d:multistatus xmlns:d=\"DAV:\">\(entries)</d:multistatus>".utf8))
            default:
                return (405, Data())
            }
        }
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: output)
        client?.urlProtocolDidFinishLoading(self)
    }
    private static func read(_ stream: InputStream?) -> Data {
        guard let stream else { return Data() }
        stream.open(); defer { stream.close() }
        var data = Data(); var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(contentsOf: buffer.prefix(count))
        }
        return data
    }
}
