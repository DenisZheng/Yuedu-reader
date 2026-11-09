import Foundation

/// Legado `cacheFirst`（LOAD_CACHE_ELSE_NETWORK）的首文档部分：命中时不发网络请求，也不重放旧响应的Set-Cookie。
/// key包含源身份、URL和实际认证头/Cookie，账号或Cookie变化只会未命中，不会跨凭据读到旧页面。
/// 只缓存通过登录检查的GET 200；no-store不写。WebKit子资源不经过这里，由系统自行处理。
/// 这是可丢弃的缓存（Caches目录），不是RSS内容的owner；读写在调用方的脚本执行器上，不在主线程。
enum RSSWebDocumentCache {
    private struct Meta: Codable { var url: String; var contentType: String }
    private static let lock = NSLock()
    private static let limit = 32 * 1_024 * 1_024
    private static let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("rss-web-documents", isDirectory: true)

    static func key(_ request: URLRequest, source: RSSSource) -> String? {
        guard source.cacheFirst == true, (request.httpMethod ?? "GET").uppercased() == "GET",
              request.httpBody == nil, request.httpBodyStream == nil, let url = request.url,
              SourceRequestHeaderScope.origin(url) != nil else { return nil }
        let headers = (request.allHTTPHeaderFields ?? [:]).map { $0.key.lowercased() + ":" + $0.value }.sorted()
        let jar = source.enabledCookieJar ? CookieStore.shared.requestHeader(for: url) : ""
        return RSSIdentity.digest([source.id, source.sourceKey, url.absoluteString, jar] + headers)
    }

    static func lookup(_ key: String) -> (Data, HTTPURLResponse)? {
        dispatchPrecondition(condition: .notOnQueue(.main))
        return lock.withLock {
            let base = directory.appendingPathComponent(key)
            guard FileManager.default.fileExists(atPath: base.appendingPathExtension("json").path) else { return nil }
            do {
                let meta = try JSONDecoder().decode(Meta.self, from: Data(contentsOf: base.appendingPathExtension("json")))
                let data = try Data(contentsOf: base.appendingPathExtension("body"))
                guard let url = URL(string: meta.url), let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                      headerFields: ["Content-Type": meta.contentType]) else { return nil }
                return (data, response)
            } catch {
                // 损坏的缓存条目只当未命中并删除，回到网络；不把它当作页面成功。
                AppLogger.parse("RSS cacheFirst entry unreadable", error: error, level: .warning)
                remove(base)
                return nil
            }
        }
    }

    static func store(_ data: Data, response: HTTPURLResponse, key: String) {
        dispatchPrecondition(condition: .notOnQueue(.main))
        guard response.statusCode == 200, data.count <= limit / 4, let url = response.url,
              response.value(forHTTPHeaderField: "Cache-Control")?.lowercased().contains("no-store") != true else { return }
        lock.withLock {
            let base = directory.appendingPathComponent(key)
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let meta = Meta(url: url.absoluteString, contentType: response.value(forHTTPHeaderField: "Content-Type") ?? "text/html")
                try data.write(to: base.appendingPathExtension("body"), options: .atomic)
                try JSONEncoder().encode(meta).write(to: base.appendingPathExtension("json"), options: .atomic)
                trim()
            } catch {
                AppLogger.parse("RSS cacheFirst write failed", error: error, level: .warning)
                remove(base)
            }
        }
    }

    /// 超出上限时按修改时间删除最旧条目。
    private static func trim() {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        let entries: [(URL, Int, Date)]
        do {
            entries = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys).map { file in
                let values = try file.resourceValues(forKeys: Set(keys))
                return (file, values.fileSize ?? 0, values.contentModificationDate ?? .distantPast)
            }
        } catch {
            AppLogger.parse("RSS cacheFirst trim failed", error: error, level: .warning)
            return
        }
        var total = entries.reduce(0) { $0 + $1.1 }
        for entry in entries.sorted(by: { $0.2 < $1.2 }) where total > limit {
            remove(entry.0.deletingPathExtension())
            total -= entry.1
        }
    }
    private static func remove(_ base: URL) {
        for ext in ["json", "body"] {
            let file = base.appendingPathExtension(ext)
            if FileManager.default.fileExists(atPath: file.path) {
                do { try FileManager.default.removeItem(at: file) }
                catch { AppLogger.parse("RSS cacheFirst remove failed", error: error, level: .warning) }
            }
        }
    }
}
