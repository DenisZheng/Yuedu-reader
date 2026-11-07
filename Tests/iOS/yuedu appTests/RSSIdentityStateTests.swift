import Foundation
import Testing
@testable import yuedu_app

@Suite("S3 RSS identity and state", .serialized)
@MainActor
struct RSSIdentityStateTests {
    @Test("同GUID跨源的已读/收藏不能串联")
    func sameGUIDAcrossSources() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { do { try FileManager.default.removeItem(at: directory) } catch { Issue.record("测试目录清理失败") } }
        let store = RSSStore(storageDirectory: directory)
        store.addSource(RSSSource(id: "one", name: "One", url: "source-one"))
        store.addSource(RSSSource(id: "two", name: "Two", url: "source-two"))
        let one = RSSItem(id: "same-guid", title: "One", link: "https://same.invalid", sourceId: "one")
        let two = RSSItem(id: "same-guid", title: "Two", link: "https://same.invalid", sourceId: "two")
        store.mergeFetchedItems([one], for: "one")
        store.mergeFetchedItems([two], for: "two")
        store.markRead(articleId: one.id, isRead: true)
        store.toggleFavorite(articleId: one.id)
        #expect(one.id != two.id)
        #expect(store.articles(for: "one").first?.isRead == true)
        #expect(store.articles(for: "two").first?.isRead == false)
        #expect(store.articles(for: "two").first?.isFavorite == false)
        try await store.flushPersistence()
    }

    @Test("分类/查询身份独立，重复页不增项且不变不写")
    func scopesAndNoChangeWrites() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { cleanup(directory) }
        let store = RSSStore(storageDirectory: directory)
        store.addSource(RSSSource(id: "scope", name: "Scope", url: "opaque"))
        let raw = RSSItem(id: "shared", title: "Shared", link: "https://same.invalid", sourceId: "scope")
        let a = raw.identified(sourceID: "scope", scope: .category(.init(name: "A", url: "a#{{page}}")))
        let b = raw.identified(sourceID: "scope", scope: .category(.init(name: "B", url: "b#{{page}}")))
        let query = raw.identified(sourceID: "scope", scope: .search("query"))
        #expect(Set([raw.id, a.id, b.id, query.id]).count == 4)
        store.mergeFetchedItems([a], for: "scope")
        store.mergeFetchedItems([b], for: "scope")
        store.mergeFetchedItems([query], for: "scope")
        store.toggleFavorite(articleId: a.id)
        try await store.flushPersistence()
        let writes = store.writeCounts
        store.mergeFetchedItems([b, b], for: "scope")
        try await store.flushPersistence()
        #expect(store.articles(for: "scope").count == 3)
        #expect(store.writeCounts == writes)
        #expect(store.article(id: b.id)?.isFavorite == false)
        store.mergeFetchedItems([], for: "scope", scope: a.scope!)
        #expect(store.article(id: a.id)?.isFavorite == true)
        store.markRead(articleId: a.id, isRead: true)
        try await store.flushPersistence()
        let readWrites = store.writeCounts
        store.markRead(articleId: a.id, isRead: true)
        try await store.flushPersistence()
        #expect(store.writeCounts == readWrites)
    }

    @Test("媒体进度只依赖稳定附件角色，URL签名变化与重启不丢进度")
    func stableMediaProgress() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { cleanup(directory) }
        let store = RSSStore(storageDirectory: directory)
        store.addSource(RSSSource(id: "media", name: "Media", url: "media-key"))
        var item = RSSItem(id: "article", title: "Media", link: "https://page.invalid/a", sourceId: "media")
        item.variables = ["article": "private variable"]
        item.media = [.init(key: "primary", articleID: item.id, kind: .video, url: "https://cdn.invalid/video?token=one")]
        store.mergeFetchedItems([item], for: "media")
        store.updateMediaProgress(articleID: item.id, attachmentKey: "primary", position: 12, duration: 90)
        store.setVariables(["source": "private source variable"], for: "media")
        item.media?[0].url = "https://cdn.invalid/video?token=two"
        store.mergeFetchedItems([item], for: "media")
        try await store.flushPersistence()
        let restored = RSSStore(storageDirectory: directory)
        let key = RSSIdentity.attachment(articleID: item.id, key: "primary")
        #expect(restored.status(for: item.id)?.mediaProgress?[key]?.position == 12)
        #expect(restored.variables(for: "media") == ["source": "private source variable"])
        #expect(restored.article(id: item.id)?.variables == item.variables)
        #expect(restored.article(id: item.id)?.media?.first?.url == "https://cdn.invalid/video?token=two")
    }

    @Test("配置与登录变化使在途票据失效")
    func requestInvalidation() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { cleanup(directory) }
        let store = RSSStore(storageDirectory: directory)
        var source = RSSSource(id: "ticket", name: "Ticket", url: "ticket-key")
        store.addSource(source)
        let first = try #require(store.requestTicket(for: source.id))
        #expect(store.accepts(first))
        source.ruleContent = "new-rule"
        store.updateSource(source)
        #expect(!store.accepts(first))
        let second = try #require(store.requestTicket(for: source.id))
        store.authenticationChanged(for: source.id)
        #expect(!store.accepts(second))
        let third = try #require(store.requestTicket(for: source.id))
        store.removeSources(ids: [source.id])
        store.addSource(source)
        #expect(!store.accepts(third))
        try await store.flushPersistence()
    }

    @Test("Fork早期记录保留所属源状态，旧歧义GUID不再路由到任意源")
    func legacyRecordDecoding() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { cleanup(directory) }
        let sources = [RSSSource(id: "a", name: "A", url: "key-a"), RSSSource(id: "b", name: "B", url: "key-b")]
        try JSONEncoder().encode(sources).write(to: directory.appendingPathComponent("rss_sources.json"))
        var objects: [String: [[String: Any]]] = [:]
        for source in sources {
            var record = RSSArticleRecord(item: RSSItem(id: "old-guid", title: source.name, link: "", sourceId: source.id))
            record.isFavorite = source.id == "a"
            var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(record)) as? [String: Any])
            json["id"] = "old-guid"
            json["identityVersion"] = nil; json["rawKey"] = nil; json["scope"] = nil
            objects[source.id] = [json]
        }
        try JSONSerialization.data(withJSONObject: objects).write(to: directory.appendingPathComponent("rss_articles.json"))
        let store = RSSStore(storageDirectory: directory)
        let a = try #require(store.articles(for: "a").first)
        let b = try #require(store.articles(for: "b").first)
        #expect(a.id != b.id && a.isFavorite && !b.isFavorite)
        #expect(store.article(id: "old-guid") == nil)
        store.markRead(articleId: a.id, isRead: true)
        #expect(store.status(for: a.id)?.isFavorite == true)
        #expect(store.article(id: b.id)?.isRead == false)
        try await store.flushPersistence()
        let reloaded = RSSStore(storageDirectory: directory)
        #expect(reloaded.article(id: a.id)?.isFavorite == true)
        #expect(reloaded.article(id: a.id)?.isRead == true)
    }

    @Test("快照校验恢复稳定身份和状态，不备份正文/签名媒体/运行变量")
    func backupRoundTripAndTamper() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { cleanup(directory) }
        let store = RSSStore(storageDirectory: directory)
        var source = RSSSource(id: "backup", name: "Backup", url: "backup-key")
        source.header = #"{"Referer":"https://page.invalid","Cookie":"private-cookie","Authorization":"private-auth"}"#
        store.addSource(source)
        var item = RSSItem(id: "article", title: "Title", link: "https://page.invalid/a?token=private-link", contentHTML: "private-body", sourceId: source.id)
        item.variables = ["login": "private-article"]
        item.media = [.init(key: "primary", articleID: item.id, kind: .video, url: "https://cdn.invalid?token=private-media")]
        store.mergeFetchedItems([item], for: source.id)
        store.toggleFavorite(articleId: item.id)
        store.updateReaderScrollY(articleId: item.id, scrollY: 123)
        store.updateMediaProgress(articleID: item.id, attachmentKey: "primary", position: 10)
        store.setVariables(["login": "private-runtime"], for: source.id)
        let backup = try await store.backupData()
        let snapshot = try await RSSBackupCodec.decode(backup)
        #expect(snapshot.sources.first?.id == source.id)
        #expect(snapshot.sources.first?.header?.contains("private-") == false)
        let envelope = try #require(JSONSerialization.jsonObject(with: backup) as? [String: Any])
        let payload = try #require((envelope["payload"] as? String).flatMap { Data(base64Encoded: $0) })
        #expect(!String(decoding: payload, as: UTF8.self).contains("private-"))
        var corrupt = envelope
        corrupt["sha256"] = "bad"
        let before = store.sources
        await #expect(throws: RSSBackupCodec.Failure.checksumMismatch) {
            try await store.restoreBackup(JSONSerialization.data(withJSONObject: corrupt))
        }
        #expect(store.sources == before)
        try await store.restoreBackup(backup)
        #expect(store.article(id: item.id)?.isFavorite == true)
        #expect(store.article(id: item.id)?.link == "")
        #expect(store.article(id: item.id)?.contentHTML == "")
        #expect(store.status(for: item.id)?.readerScrollY == 123)
        #expect(store.variables(for: source.id).isEmpty)
        let key = RSSIdentity.attachment(articleID: item.id, key: "primary")
        #expect(store.status(for: item.id)?.mediaProgress?[key]?.position == 10)
        #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("rss-restore-backups").path))
        // 非收藏条目可以离开内容缓存，但其已读记录仍要进入快照。
        store.toggleFavorite(articleId: item.id)
        store.markRead(articleId: item.id, isRead: true)
        store.mergeFetchedItems([], for: source.id)
        let withoutContent = try await RSSBackupCodec.decode(store.backupData())
        #expect(withoutContent.statuses.first { $0.articleId == item.id }?.isRead == true)
        let secondBackup = try await store.backupData()
        try await store.restoreBackup(secondBackup)
        #expect(store.totalUnreadCount() == 0)
        store.markRead(articleId: item.id, isRead: false)
        #expect(store.totalUnreadCount() == 1)
        try await store.flushPersistence()
        var unsupported = snapshot; unsupported.schemaVersion = 99
        #expect(throws: RSSBackupCodec.Failure.unsupportedVersion) { try RSSBackupCodec.validate(unsupported) }
    }

    private func cleanup(_ url: URL) {
        do { try FileManager.default.removeItem(at: url) }
        catch { Issue.record("测试目录清理失败") }
    }

    @Test("删除后晚到数据不能重新写入缓存或创建状态")
    func deletedSourceCannotReturn() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { do { try FileManager.default.removeItem(at: directory) } catch { Issue.record("测试目录清理失败") } }
        let store = RSSStore(storageDirectory: directory)
        let source = RSSSource(id: "deleted", name: "Delete", url: "deleted-key")
        let item = RSSItem(id: "late", title: "Late", link: "", sourceId: source.id)
        store.addSource(source)
        store.mergeFetchedItems([item], for: source.id)
        store.removeSources(ids: [source.id])
        store.mergeFetchedItems([item], for: source.id)
        store.markRead(articleId: item.id, isRead: true)
        #expect(store.article(id: item.id) == nil)
        #expect(store.status(for: item.id) == nil)
        try await store.flushPersistence()
    }
}
