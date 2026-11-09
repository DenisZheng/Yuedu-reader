import Foundation
import Network

/// 仅供当前 AVPlayer 的 loopback HTTP 端点。随机 capability 只索引本源已准备的根资源及其 HLS 清单明确列出的资源；
/// 不接受外部 URL、文件路径、请求头或写操作，不使用 AVURLAsset 的 asset-wide 私有头选项。
/// NWListener 要求显式回调队列；IO、清单改写和上游请求都不占主线程。停止会话立即关闭 listener/连接/请求。
final class RSSMediaResourceSession: @unchecked Sendable {
    struct Reply: Sendable {
        var status: Int
        var headers: [String: String]
        var body: Data
    }
    private struct Client {
        var connection: NWConnection
        var work: Task<Void, Never>?
        var deadline: Task<Void, Never>?
    }
    private let listener: NWListener
    private let queue = DispatchQueue(label: "reader.rss.media.http", qos: .userInitiated)
    private let lock = NSLock()
    private var clients: [ObjectIdentifier: Client] = [:]
    private var closed = false
    private var startWaiter: CheckedContinuation<URL, Error>?
    private var requests = 0
    private var cancellation: UUID?
    private var loginObserver: NSObjectProtocol?
    private var stopHandler: (@Sendable () -> Void)?
    private var hasStarted = false
    private let prepared: RSSMediaRequestService.Prepared
    private let graph: RSSMediaResourceGraph
    private let rootPath: String

    init(_ prepared: RSSMediaRequestService.Prepared) throws {
        try RSSMediaRequestService.validate(prepared)
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        listener = try NWListener(using: parameters)
        self.prepared = prepared
        let nonce = UUID().uuidString + UUID().uuidString
        rootPath = "/" + nonce + "/0/stream" + (prepared.request.url?.pathExtension.lowercased() == "m3u8" ? ".m3u8" : ".mp4")
        graph = RSSMediaResourceGraph(prepared: prepared, rootPath: rootPath, prefix: "/" + nonce)
    }
    deinit { stop() }

    func start() async throws -> VideoStream {
        let url = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let allowed = lock.withLock { () -> Bool in
                    guard !closed, !hasStarted else { return false }
                    hasStarted = true
                    startWaiter = continuation
                    return true
                }
                guard allowed else { continuation.resume(throwing: CancellationError()); return }
                listener.stateUpdateHandler = { [weak self] state in
                    guard let self else { return }
                    switch state {
                    case .ready:
                        guard let port = listener.port,
                              let url = URL(string: "http://127.0.0.1:\(port.rawValue)\(rootPath)") else {
                            stop(); return
                        }
                        let waiter = lock.withLock { () -> CheckedContinuation<URL, Error>? in
                            let value = startWaiter; startWaiter = nil; return value
                        }
                        waiter?.resume(returning: url)
                    case .failed: stop()
                    default: break
                    }
                }
                listener.newConnectionHandler = { [weak self] client in self?.accept(client) }
                listener.start(queue: queue)
            }
        } onCancel: { self.stop() }
        try Task.checkCancellation()
        guard prepared.runtime.state.isCurrent else { stop(); throw CancellationError() }
        await graph.setBase(url)
        do {
            guard let token = prepared.runtime.state.addCancellation({ [weak self] in self?.stop() }) else { throw CancellationError() }
            let installed = lock.withLock { () -> Bool in
                guard !closed else { return false }
                cancellation = token
                return true
            }
            if !installed { prepared.runtime.state.removeCancellation(token); throw CancellationError() }
            let key = RSSRuntime.authenticationKey(for: prepared.runtime.source)
            let observer = NotificationCenter.default.addObserver(forName: .bookSourceLoginInfoDidChange, object: nil, queue: nil) { [weak self] note in
                guard let self, note.userInfo?["sourceURL"] as? String == key, !prepared.runtime.state.isCurrent else { return }
                stop()
            }
            let observing = lock.withLock { () -> Bool in
                guard !closed else { return false }
                loginObserver = observer
                return true
            }
            if !observing { NotificationCenter.default.removeObserver(observer); throw CancellationError() }
            guard prepared.runtime.state.isCurrent else { throw CancellationError() }
            return VideoStream(url: url, headers: [:], stopResource: { [self] in stop() })
        } catch { stop(); throw error }
    }

    /// 当前会话只有一个播放器consumer；撤销时先停止已缓冲播放，而不是等下一个HTTP请求失败。
    func onStop(_ action: (@Sendable () -> Void)?) {
        let notify = lock.withLock { () -> Bool in
            guard !closed else { return true }
            stopHandler = action
            return false
        }
        if notify { action?() }
    }
    func stop() {
        let pending = lock.withLock { () -> ([Client], CheckedContinuation<URL, Error>?, UUID?, NSObjectProtocol?, (@Sendable () -> Void)?)? in
            guard !closed else { return nil }
            closed = true
            let value = (Array(clients.values), startWaiter, cancellation, loginObserver, stopHandler)
            clients.removeAll(); startWaiter = nil; cancellation = nil; loginObserver = nil; stopHandler = nil
            return value
        }
        guard let pending else { return }
        listener.cancel()
        pending.1?.resume(throwing: CancellationError())
        for client in pending.0 { client.work?.cancel(); client.deadline?.cancel(); client.connection.cancel() }
        if let token = pending.2 { prepared.runtime.state.removeCancellation(token) }
        if let observer = pending.3 { NotificationCenter.default.removeObserver(observer) }
        pending.4?()
        let graph = graph
        Task { await graph.stop() }
    }

    private func accept(_ connection: NWConnection) {
        let id = ObjectIdentifier(connection)
        let allowed = lock.withLock { () -> Bool in
            guard !closed, clients.count < 12, requests < 16_384 else { return false }
            requests += 1; clients[id] = Client(connection: connection)
            return true
        }
        guard allowed else { connection.cancel(); return }
        // 防本地不完整HTTP请求耗尽连接；这是输入超时，不是等待UI稳定。
        let deadline = Task { [weak self, weak connection] in
            do { try await Task.sleep(for: .seconds(35)) } catch { return }
            if let connection { self?.finish(connection) }
        }
        lock.withLock { clients[id]?.deadline = deadline }
        connection.start(queue: queue)
        receive(connection, accumulated: Data())
    }
    private func receive(_ connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4_096) { [weak self] data, _, complete, error in
            guard let self else { connection.cancel(); return }
            var bytes = accumulated
            if let data { bytes.append(data) }
            guard error == nil, bytes.count <= 16_384 else { finish(connection); return }
            if let end = bytes.range(of: Data("\r\n\r\n".utf8)) {
                guard end.upperBound == bytes.count else { finish(connection); return }
                handle(connection, bytes: bytes)
            } else if complete { finish(connection) }
            else { receive(connection, accumulated: bytes) }
        }
    }
    private func handle(_ connection: NWConnection, bytes: Data) {
        guard let text = String(data: bytes, encoding: .utf8) else { finish(connection); return }
        let lines = text.components(separatedBy: "\r\n")
        let first = (lines.first ?? "").split(separator: " ")
        guard first.count == 3, ["GET", "HEAD"].contains(String(first[0])), first[2] == "HTTP/1.1" else { finish(connection); return }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() where !line.isEmpty {
            guard let separator = line.firstIndex(of: ":") else { finish(connection); return }
            let name = line[..<separator].lowercased()
            guard headers[name] == nil else { finish(connection); return }
            headers[name] = line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)
        }
        // 不是网页网络代理，也不接收HTTP消息体/升级或任意转发头。
        guard headers["origin"] == nil, headers["transfer-encoding"] == nil,
              headers["content-length"].map({ $0 == "0" }) ?? true,
              headers["host"] == listener.port.map({ "127.0.0.1:\($0.rawValue)" }) else { finish(connection); return }
        let method = String(first[0]), path = String(first[1]), range = headers["range"]
        let work = Task { [weak self] in
            guard let self else { return }
            let reply: Reply
            do {
                reply = try await graph.reply(path: path, method: method, range: range)
                try Task.checkCancellation()
                guard prepared.runtime.state.isCurrent else { throw CancellationError() }
            } catch is CancellationError { finish(connection); return }
            catch {
                // 不把URL、上游异常、认证或密钥写入响应/日志。
                AppLogger.network("RSS media resource failed", context: ["stage": "rss.media.resource"], level: .warning)
                send(.init(status: 502, headers: [:], body: Data()), to: connection, head: method == "HEAD")
                return
            }
            send(reply, to: connection, head: method == "HEAD")
        }
        let installed = lock.withLock { () -> Bool in
            guard clients[ObjectIdentifier(connection)] != nil, !closed else { return false }
            clients[ObjectIdentifier(connection)]?.work = work
            return true
        }
        if !installed { work.cancel() }
    }
    private func send(_ reply: Reply, to connection: NWConnection, head: Bool) {
        guard lock.withLock({ !closed && clients[ObjectIdentifier(connection)] != nil }) else { return }
        var header = "HTTP/1.1 \(reply.status) Resource\r\nConnection: close\r\nCache-Control: no-store\r\n"
        for (name, value) in reply.headers {
            guard !value.contains("\r"), !value.contains("\n") else { finish(connection); return }
            header += "\(name): \(value)\r\n"
        }
        header += "\r\n"
        var data = Data(header.utf8)
        if !head { data.append(reply.body) }
        connection.send(content: data, completion: .contentProcessed { [weak self] _ in self?.finish(connection) })
    }
    private func finish(_ connection: NWConnection) {
        let client = lock.withLock { clients.removeValue(forKey: ObjectIdentifier(connection)) }
        client?.work?.cancel(); client?.deadline?.cancel(); connection.cancel()
    }
}

/// 只缓存当前播放所需的有界Range/分片工作集，关闭即丢弃；不是RSS持久内容的第二份owner。
private actor RSSMediaResourceGraph {
    private enum Kind { case root, playlist, media }
    private struct Resource { var url: URL; var kind: Kind }
    private struct Loaded: Sendable { var data: Data; var response: HTTPURLResponse }
    private let prepared: RSSMediaRequestService.Prepared
    private let rootPath: String
    private let prefix: String
    private let permitted: SourceRequestHeaderScope
    private var base: URL?
    private var closed = false
    private var resources: [String: Resource]
    private var paths: [String: String] = [:]
    private var pending: [String: Task<Loaded, Error>] = [:]
    private var cache: [String: Loaded] = [:]
    private var cacheOrder: [String] = []
    private var cacheBytes = 0
    private static let chunk = 2 * 1_024 * 1_024
    private static let memory = 32 * 1_024 * 1_024

    init(prepared: RSSMediaRequestService.Prepared, rootPath: String, prefix: String) {
        self.prepared = prepared; self.rootPath = rootPath; self.prefix = prefix
        let url = prepared.request.url!
        permitted = SourceRequestHeaderScope(urls: [url])
        resources = [rootPath: Resource(url: url, kind: url.pathExtension.lowercased() == "m3u8" ? .playlist : .root)]
        paths[url.absoluteString] = rootPath
    }
    func setBase(_ url: URL) { base = url }
    func stop() {
        closed = true
        for task in pending.values { task.cancel() }
        pending.removeAll(); cache.removeAll(); cacheOrder.removeAll(); resources.removeAll(); paths.removeAll(); cacheBytes = 0
    }
    func reply(path: String, method: String, range: String?) async throws -> RSSMediaResourceSession.Reply {
        guard !closed, let resource = resources[path], let base else { throw RSSWebFailure.resourceUnavailable }
        try await prepared.context.validate(source: prepared.runtime.source, owner: prepared.runtime.owner)
        guard prepared.runtime.state.isCurrent else { throw CancellationError() }
        let requested = try range.map(RSSMediaByteRange.init)
        let upstreamRange: String?
        if method == "HEAD" || resource.kind == .playlist { upstreamRange = nil }
        else if let requested {
            let start = requested.start ?? 0
            if requested.start == nil { upstreamRange = "bytes=-\(min(requested.end ?? Int64(Self.chunk), Int64(Self.chunk)))" }
            else {
                let aligned = start / Int64(Self.chunk) * Int64(Self.chunk)
                upstreamRange = "bytes=\(aligned)-\(aligned + Int64(Self.chunk) - 1)"
            }
        } else { upstreamRange = resource.kind == .root ? "bytes=0-\(Self.chunk - 1)" : nil }
        let key = RSSIdentity.digest([resource.url.absoluteString, method, upstreamRange ?? ""])
        let loaded: Loaded
        if let value = cache[key] { loaded = value }
        else if let task = pending[key] { loaded = try await task.value }
        else {
            guard pending.count < 6 else { throw RSSWebFailure.resourceUnavailable }
            let prepared = prepared, permitted = permitted
            let task = Task {
                var request = URLRequest(url: resource.url)
                request.httpMethod = method
                for (name, value) in permitted.inheritedHeaders(prepared.request.allHTTPHeaderFields ?? [:], for: resource.url)
                    where !["host", "content-length", "content-type", "range", "accept-encoding"].contains(name.lowercased()) {
                    request.setValue(value, forHTTPHeaderField: name)
                }
                request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
                request.setValue(upstreamRange, forHTTPHeaderField: "Range")
                let source = prepared.runtime.source
                let executor = SourceRequestExecutor(session: prepared.runtime.requestSession, rate: source.concurrentRate ?? "",
                    rateKey: RSSRuntime.authenticationKey(for: source), cookieJarEnabled: source.enabledCookieJar,
                    runtimeState: prepared.runtime.state, cookieScope: permitted,
                    maximumBytes: resource.kind == .playlist ? 1_024 * 1_024 : 16 * 1_024 * 1_024,
                    requestValidator: { try RSSImageService.validateResourceURL($0, permitted: permitted, trusted: false) })
                let (data, response) = try await executor.data(for: request)
                guard let response = response as? HTTPURLResponse,
                      (200..<300).contains(response.statusCode) || response.statusCode == 416 else { throw RSSWebFailure.resourceUnavailable }
                return Loaded(data: data, response: response)
            }
            pending[key] = task
            defer { pending.removeValue(forKey: key) }
            loaded = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            try Task.checkCancellation()
            guard !closed, prepared.runtime.state.isCurrent else { throw CancellationError() }
            let manifest = resource.kind == .playlist || loaded.data.starts(with: Data("#EXTM3U".utf8))
            if method == "GET", !manifest, loaded.data.count <= Self.memory {
                while cacheBytes + loaded.data.count > Self.memory, !cacheOrder.isEmpty {
                    let oldest = cacheOrder.removeFirst()
                    cacheBytes -= cache.removeValue(forKey: oldest)?.data.count ?? 0
                }
                cache[key] = loaded; cacheOrder.append(key); cacheBytes += loaded.data.count
            }
        }
        try Task.checkCancellation()
        guard !closed, prepared.runtime.state.isCurrent else { throw CancellationError() }
        if loaded.response.statusCode == 416 {
            guard let value = loaded.response.value(forHTTPHeaderField: "Content-Range"), value.hasPrefix("bytes */"),
                  let total = Int64(value.dropFirst(8)), total >= 0 else { throw RSSWebFailure.resourceUnavailable }
            return unsatisfied(total: total)
        }
        let isManifest = resource.kind == .playlist || loaded.data.starts(with: Data("#EXTM3U".utf8))
        if isManifest, method != "HEAD" {
            let data = try rewrite(loaded.data, relativeTo: loaded.response.url ?? resource.url, base: base)
            return .init(status: 200, headers: ["Content-Type": "application/vnd.apple.mpegurl", "Content-Length": String(data.count)], body: data)
        }
        var headers = ["Content-Type": loaded.response.mimeType ?? "application/octet-stream", "Accept-Ranges": "bytes"]
        if method == "HEAD" {
            headers["Content-Length"] = loaded.response.value(forHTTPHeaderField: "Content-Length") ?? "0"
            return .init(status: loaded.response.statusCode, headers: headers, body: Data())
        }
        let bounds = try RSSMediaByteRange.response(loaded.response, byteCount: loaded.data.count)
        if let requested {
            let start = requested.start ?? max(0, bounds.total - (requested.end ?? 0))
            let requestedEnd = requested.start == nil ? bounds.total - 1 : requested.end ?? bounds.total - 1
            let end = min(requestedEnd, bounds.end)
            if start >= bounds.total { return unsatisfied(total: bounds.total) }
            guard start >= bounds.start, start <= end else { throw RSSWebFailure.resourceUnavailable }
            let data = loaded.data.subdata(in: Int(start - bounds.start)..<Int(end - bounds.start + 1))
            headers["Content-Length"] = String(data.count)
            headers["Content-Range"] = "bytes \(start)-\(end)/\(bounds.total)"
            return .init(status: 206, headers: headers, body: data)
        }
        headers["Content-Length"] = String(loaded.data.count)
        if loaded.response.statusCode == 206 { headers["Content-Range"] = "bytes \(bounds.start)-\(bounds.end)/\(bounds.total)" }
        return .init(status: loaded.response.statusCode, headers: headers, body: loaded.data)
    }

    private func unsatisfied(total: Int64) -> RSSMediaResourceSession.Reply {
        .init(status: 416, headers: ["Content-Range": "bytes */\(total)", "Content-Length": "0"], body: Data())
    }
    private func rewrite(_ data: Data, relativeTo url: URL, base: URL) throws -> Data {
        try SourcePerfTrace.span("rss.media.playlist", "main=\(Thread.isMainThread),bytes=\(data.count)") {
            guard data.count <= 1_024 * 1_024, let text = String(data: data, encoding: .utf8), text.hasPrefix("#EXTM3U") else { throw RSSWebFailure.resourceUnavailable }
            let lines = text.components(separatedBy: .newlines)
            guard lines.count <= 8_192 else { throw RSSWebFailure.resourceUnavailable }
            let pattern = try NSRegularExpression(pattern: "(?<=[:,])URI=\"([^\"]*)\"")
            var nextIsPlaylist = false
            let rewritten = try lines.map { line -> String in
                guard !line.hasPrefix("#EXT-X-CONTENT-STEERING"), !line.hasPrefix("#EXT-X-DEFINE"),
                      !(line.hasPrefix("#EXT-X-DATERANGE") && line.contains("X-ASSET")),
                      !line.contains("METHOD=SAMPLE-AES"), !line.contains("KEYFORMAT=\"") || line.contains("KEYFORMAT=\"identity\"")
                else { throw RSSWebFailure.resourceUnavailable }
                if line.hasPrefix("#EXT-X-STREAM-INF") { nextIsPlaylist = true }
                if line.hasPrefix("#") {
                    var result = line
                    let matches = pattern.matches(in: line, range: NSRange(line.startIndex..., in: line))
                    if line.contains("URI="), matches.isEmpty { throw RSSWebFailure.resourceUnavailable }
                    for match in matches.reversed() {
                        guard let range = Range(match.range(at: 1), in: result) else { throw RSSWebFailure.resourceUnavailable }
                        let playlist = line.hasPrefix("#EXT-X-MEDIA:") || line.contains("STREAM-INF:")
                        result.replaceSubrange(range, with: try register(String(result[range]), relativeTo: url, base: base, playlist: playlist))
                    }
                    return result
                }
                guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { return line }
                let playlist = nextIsPlaylist; nextIsPlaylist = false
                return try register(line.trimmingCharacters(in: .whitespaces), relativeTo: url, base: base, playlist: playlist)
            }
            return Data(rewritten.joined(separator: "\n").utf8)
        }
    }
    private func register(_ raw: String, relativeTo url: URL, base: URL, playlist: Bool) throws -> String {
        let target = try RSSWebActionRouter.pageURL(raw, base: url)
        try RSSImageService.validateResourceURL(target, permitted: permitted, trusted: false)
        if let path = paths[target.absoluteString] { return localURL(for: path, base: base) }
        guard resources.count < 4_096 else { throw RSSWebFailure.resourceUnavailable }
        let isPlaylist = playlist || target.pathExtension.lowercased() == "m3u8"
        let path = prefix + "/\(resources.count)/resource" + (isPlaylist ? ".m3u8" : ".bin")
        resources[path] = Resource(url: target, kind: isPlaylist ? .playlist : .media)
        paths[target.absoluteString] = path
        return localURL(for: path, base: base)
    }
    private func localURL(for path: String, base: URL) -> String {
        var components = URLComponents(url: base, resolvingAgainstBaseURL: false)!
        components.path = path; components.query = nil; components.fragment = nil
        return components.url!.absoluteString
    }
}

private struct RSSMediaByteRange {
    var start: Int64?
    var end: Int64?
    init(_ raw: String) throws {
        guard raw.hasPrefix("bytes="), !raw.contains(",") else { throw RSSWebFailure.resourceUnavailable }
        let parts = raw.dropFirst(6).split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 2 else { throw RSSWebFailure.resourceUnavailable }
        start = parts[0].isEmpty ? nil : Int64(parts[0]); end = parts[1].isEmpty ? nil : Int64(parts[1])
        guard (parts[0].isEmpty || start != nil), (parts[1].isEmpty || end != nil),
              start.map({ $0 >= 0 && $0 <= Int64.max - 4_194_304 }) ?? true,
              end.map({ $0 >= 0 && (start != nil || $0 > 0) }) ?? (start != nil), start != nil || end != nil,
              start == nil || end == nil || start! <= end! else { throw RSSWebFailure.resourceUnavailable }
    }
    static func response(_ response: HTTPURLResponse, byteCount: Int) throws -> (start: Int64, end: Int64, total: Int64) {
        guard response.statusCode == 206 else { return (0, Int64(byteCount) - 1, Int64(byteCount)) }
        guard let value = response.value(forHTTPHeaderField: "Content-Range"), value.hasPrefix("bytes ") else { throw RSSWebFailure.resourceUnavailable }
        let pair = value.dropFirst(6).split(separator: "/"), range = pair.first?.split(separator: "-") ?? []
        guard pair.count == 2, range.count == 2, let start = Int64(range[0]), let end = Int64(range[1]), let total = Int64(pair[1]),
              start >= 0, end >= start, total > end, end - start + 1 == byteCount else { throw RSSWebFailure.resourceUnavailable }
        return (start, end, total)
    }
}
