import Foundation
import CryptoKit

/// Fork私有的配置/状态快照。没有正文、附件URL、CookieStore或运行时变量。
enum RSSBackupCodec {
    static let schemaVersion = 1
    static let maximumBytes = 64 * 1024 * 1024

    struct Article: Codable, Sendable {
        var id: String
        var sourceID: String
        var title: String
        var scope: RSSArticleScope
    }

    struct Snapshot: Codable, Sendable {
        var schemaVersion: Int
        var sources: [RSSSource]
        var folders: [RSSFolder]
        var articles: [Article]
        var statuses: [RSSArticleStatus]
    }

    private struct Envelope: Codable {
        var format: String
        var payload: Data
        var sha256: String
    }

    enum Failure: LocalizedError {
        case invalidSnapshot, unsupportedVersion, checksumMismatch, tooLarge, rollbackFailed
        var errorDescription: String? {
            switch self {
            case .rollbackFailed: localized("還原失敗，原始資料副本已保留，請勿繼續同步")
            case .unsupportedVersion: localized("此 RSS 備份版本尚不支援，未還原訂閱資料")
            case .invalidSnapshot, .checksumMismatch, .tooLarge: localized("RSS 備份校驗失敗或超過大小限制，未還原訂閱資料")
            }
        }
    }

    nonisolated static func encode(sources: [RSSSource], folders: [RSSFolder],
                                  records: [String: [RSSArticleRecord]], statuses: [String: RSSArticleStatus]) async throws -> Data {
        try SourcePerfTrace.span("rss.backup.encode", "main=\(Thread.isMainThread) sources=\(sources.count)") {
            var snapshotSources = sources
            for index in snapshotSources.indices {
                // 此处只去掉运行时值和静态认证头，源作者的JS配置仍原样备份、不执行。
                snapshotSources[index].variable = nil
                snapshotSources[index].resolvedFeedURL = nil
                if let header = snapshotSources[index].header,
                   let data = header.data(using: .utf8), header.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("{") {
                    let object = try JSONSerialization.jsonObject(with: data)
                    guard let headers = object as? [String: Any] else { throw Failure.invalidSnapshot }
                    let redacted = headers.filter { !["cookie", "authorization", "proxy-authorization", "set-cookie"].contains($0.key.lowercased()) }
                    let clean = try JSONSerialization.data(withJSONObject: redacted, options: [.sortedKeys])
                    snapshotSources[index].header = String(decoding: clean, as: UTF8.self)
                }
            }
            var refs: [Article] = []
            var state: [RSSArticleStatus] = []
            let sourcesByID = Set(sources.map(\.id))
            var seen = Set<String>()
            for record in records.values.joined() where sourcesByID.contains(record.sourceId) && seen.insert(record.id).inserted {
                refs.append(Article(id: record.id, sourceID: record.sourceId, title: record.title, scope: record.scope ?? .feed))
                var value = statuses[record.id] ?? RSSArticleStatus(articleId: record.id,
                    isRead: record.isRead, isFavorite: record.isFavorite, lastOpenedAt: record.lastOpenedAt, readerScrollY: record.readerScrollY)
                value.sourceID = record.sourceId
                value.identityVersion = RSSIdentity.version
                value.scope = record.scope ?? .feed
                state.append(value)
            }
            // 正文缓存被刷新淘汰后，已读/进度仍是持久状态，不能从备份中丢掉。
            for value in statuses.values where value.identityVersion == RSSIdentity.version {
                guard let sourceID = value.sourceID, sourcesByID.contains(sourceID), seen.insert(value.articleId).inserted else { continue }
                refs.append(Article(id: value.articleId, sourceID: sourceID, title: "", scope: value.scope ?? .feed))
                state.append(value)
            }
            let snapshot = Snapshot(schemaVersion: schemaVersion, sources: snapshotSources, folders: folders,
                                    articles: refs.sorted { $0.id < $1.id }, statuses: state.sorted { $0.articleId < $1.articleId })
            try validate(snapshot)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let payload = try encoder.encode(snapshot)
            guard payload.count <= maximumBytes else { throw Failure.tooLarge }
            return try encoder.encode(Envelope(format: "reader-fork-rss", payload: payload, sha256: hash(payload)))
        }
    }

    nonisolated static func decode(_ data: Data) async throws -> Snapshot {
        try SourcePerfTrace.span("rss.backup.decode", "main=\(Thread.isMainThread) bytes=\(data.count)") {
            guard data.count <= maximumBytes * 2 else { throw Failure.tooLarge }
            let envelope = try JSONDecoder().decode(Envelope.self, from: data)
            guard envelope.format == "reader-fork-rss", envelope.payload.count <= maximumBytes else { throw Failure.invalidSnapshot }
            guard hash(envelope.payload) == envelope.sha256 else { throw Failure.checksumMismatch }
            let snapshot = try JSONDecoder().decode(Snapshot.self, from: envelope.payload)
            try validate(snapshot)
            return snapshot
        }
    }

    static func validate(_ snapshot: Snapshot) throws {
        guard snapshot.schemaVersion == schemaVersion else { throw Failure.unsupportedVersion }
        guard snapshot.sources.count <= 2000, snapshot.articles.count <= 200_000 else { throw Failure.tooLarge }
        guard snapshot.sources.allSatisfy({ !$0.id.isEmpty && !$0.sourceKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && ($0.configurationVersion == nil || $0.configurationVersion == 1) }) else { throw Failure.invalidSnapshot }
        let sources = Set(snapshot.sources.map(\.id))
        let articles = Set(snapshot.articles.map(\.id))
        guard sources.count == snapshot.sources.count,
              Set(snapshot.sources.map(\.sourceKey)).count == snapshot.sources.count,
              articles.count == snapshot.articles.count,
              Set(snapshot.folders.map(\.id)).count == snapshot.folders.count,
              Set(snapshot.statuses.map(\.articleId)).count == snapshot.statuses.count else { throw Failure.invalidSnapshot }
        let articleSources = Dictionary(uniqueKeysWithValues: snapshot.articles.map { ($0.id, $0.sourceID) })
        for article in snapshot.articles {
            guard sources.contains(article.sourceID), article.id.hasPrefix("rss1:"), article.id.count == 69,
                  article.id.dropFirst(5).allSatisfy({ $0.isHexDigit }) else { throw Failure.invalidSnapshot }
        }
        for status in snapshot.statuses {
            guard articles.contains(status.articleId), status.sourceID == articleSources[status.articleId],
                  status.identityVersion == RSSIdentity.version, status.readerScrollY.isFinite,
                  status.readerScrollY >= 0 else { throw Failure.invalidSnapshot }
            for progress in status.mediaProgress?.values ?? Dictionary<String, RSSMediaProgress>().values {
                guard progress.position.isFinite, progress.position >= 0,
                      progress.duration == nil || (progress.duration!.isFinite && progress.duration! >= 0) else { throw Failure.invalidSnapshot }
            }
        }
    }

    nonisolated static func materialize(_ snapshot: Snapshot) async -> [String: [RSSArticleRecord]] {
        Dictionary(grouping: snapshot.articles.map { reference in
            // 已验证的稳定ID直接恢复；不杜撰URL或把旧签名地址当可播放资源。
            var article = RSSArticleRecord(item: RSSItem(id: reference.id, title: reference.title, link: "", sourceId: reference.sourceID),
                                           fetchedAt: Date(timeIntervalSince1970: 0))
            article.id = reference.id
            article.rawKey = nil
            article.scope = reference.scope
            return article
        }, by: \.sourceId)
    }

    private static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
