import Foundation
import Network

/// 视频帧与 RSS 媒体 PoC 共用的测试服务器：仅本机、临时端口、有限请求，不代理外站。
/// 固定文件只允许访问给定目录的直接子文件；测试路由显式给出响应与必要头部。
final class VideoStillFixtureServer: @unchecked Sendable {
    struct Request: CustomStringConvertible {
        let method: String
        let path: String
        let headers: [String: String]
        var referer: String? { headers["referer"] }
        var description: String { "\(method) \(path)" }
    }

    struct Response: Sendable {
        var body: Data
        var type = "text/html; charset=utf-8"
        var status = "200 OK"
        var headers: [String: String] = [:]
        var requiredHeaders: [String: String] = [:]
    }

    private let directory: URL
    private let referer: String?
    private let routes: [String: Response]
    private let listener: NWListener
    private let queue = DispatchQueue(label: "VideoStillFixtureServer")
    private let lock = NSLock()
    private var continuation: CheckedContinuation<URL, Error>?
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var received: [Request] = []

    init(directory: URL, referer: String? = nil, routes: [String: Response] = [:]) throws {
        self.directory = directory
        self.referer = referer
        self.routes = routes
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
    }

    var requests: [Request] { lock.withLock { received } }

    func start() async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            lock.withLock { self.continuation = continuation }
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    guard let port = self.listener.port,
                          let url = URL(string: "http://127.0.0.1:\(port.rawValue)/") else {
                        self.finishStart(.failure(URLError(.cannotConnectToHost)))
                        return
                    }
                    self.finishStart(.success(url))
                case .failed(let error): self.finishStart(.failure(error))
                case .cancelled: self.finishStart(.failure(CancellationError()))
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                guard let self else { connection.cancel(); return }
                let accepted = self.lock.withLock {
                    guard self.connections.count < 16 else { return false }
                    self.connections[ObjectIdentifier(connection)] = connection
                    return true
                }
                guard accepted else { connection.cancel(); return }
                connection.start(queue: self.queue)
                self.receiveHeaders(connection, accumulated: Data())
            }
            listener.start(queue: queue)
        }
    }

    func stop() {
        listener.stateUpdateHandler = nil
        listener.newConnectionHandler = nil
        listener.cancel()
        let open = lock.withLock {
            let value = Array(connections.values)
            connections.removeAll()
            return value
        }
        open.forEach { $0.cancel() }
        finishStart(.failure(CancellationError()))
    }

    private func close(_ connection: NWConnection) {
        _ = lock.withLock { connections.removeValue(forKey: ObjectIdentifier(connection)) }
        connection.cancel()
    }

    private func finishStart(_ result: Result<URL, Error>) {
        let callback = lock.withLock { let value = continuation; continuation = nil; return value }
        callback?.resume(with: result)
    }

    private func receiveHeaders(_ connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] chunk, _, complete, error in
            guard let self else { connection.cancel(); return }
            var request = accumulated
            if let chunk { request.append(chunk) }
            guard error == nil, request.count < 64 * 1024 else { self.close(connection); return }
            if let boundary = request.range(of: Data("\r\n\r\n".utf8)),
               let text = String(data: request[..<boundary.lowerBound], encoding: .utf8) {
                self.respond(connection, headers: text)
            } else if !complete {
                self.receiveHeaders(connection, accumulated: request)
            } else { self.close(connection) }
        }
    }

    private func respond(_ connection: NWConnection, headers raw: String) {
        let lines = raw.components(separatedBy: "\r\n")
        let first = lines[0].split(separator: " ")
        guard first.count == 3 else { close(connection); return }
        let method = String(first[0])
        let path = String(first[1]).components(separatedBy: "?")[0]
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[String(line[..<colon]).lowercased()] = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
        }
        let withinBudget = lock.withLock {
            guard received.count < 128 else { return false }
            received.append(Request(method: method, path: path, headers: headers))
            return true
        }
        guard withinBudget else { return send(connection, status: "429 Too Many Requests", body: Data()) }
        guard method == "GET" || method == "HEAD" else { return send(connection, status: "405 Method Not Allowed", body: Data()) }

        let response: Response
        if let route = routes[path] {
            response = route
        } else {
            let name = String(path.dropFirst())
            guard !name.isEmpty, !name.contains("/"), !name.contains("%"), name != ".", name != ".." else {
                return send(connection, status: "404 Not Found", body: Data())
            }
            let file = directory.appendingPathComponent(name)
            do {
                let data = try Data(contentsOf: file)
                let type = switch file.pathExtension {
                case "m3u8": "application/vnd.apple.mpegurl"
                case "m4s": "video/iso.segment"
                case "m4a": "audio/mp4"
                case "png": "image/png"
                default: "video/mp4"
                }
                response = Response(body: data, type: type, requiredHeaders: referer.map { ["referer": $0] } ?? [:])
            } catch {
                return send(connection, status: "404 Not Found", body: Data())
            }
        }
        guard response.requiredHeaders.allSatisfy({ headers[$0.key.lowercased()] == $0.value }) else {
            return send(connection, status: "403 Forbidden", body: Data())
        }
        var extra = response.headers
        extra["Content-Type"] = response.type
        extra["Accept-Ranges"] = "bytes"
        if method == "GET", response.status == "200 OK", let range = headers["range"] {
            guard let bounds = Self.bounds(range, count: response.body.count) else {
                extra["Content-Range"] = "bytes */\(response.body.count)"
                return send(connection, status: "416 Range Not Satisfiable", body: Data(), headers: extra)
            }
            extra["Content-Range"] = "bytes \(bounds.lowerBound)-\(bounds.upperBound - 1)/\(response.body.count)"
            return send(connection, status: "206 Partial Content", body: response.body.subdata(in: bounds), headers: extra)
        }
        send(connection, status: response.status, body: response.body, headers: extra, headOnly: method == "HEAD")
    }

    private static func bounds(_ range: String, count: Int) -> Range<Int>? {
        guard range.hasPrefix("bytes="), count > 0 else { return nil }
        let parts = range.dropFirst(6).split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        if parts[0].isEmpty {
            guard let suffix = Int(parts[1]), suffix > 0 else { return nil }
            return max(0, count - suffix)..<count
        }
        guard let start = Int(parts[0]), start >= 0, start < count else { return nil }
        if parts[1].isEmpty { return start..<count }
        guard let end = Int(parts[1]), end >= start else { return nil }
        return start..<(min(end, count - 1) + 1)
    }

    private func send(_ connection: NWConnection, status: String, body: Data, headers: [String: String] = [:], headOnly: Bool = false) {
        var head = "HTTP/1.1 \(status)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n"
        for (name, value) in headers { head += "\(name): \(value)\r\n" }
        var response = Data((head + "\r\n").utf8)
        if !headOnly { response.append(body) }
        connection.send(content: response, completion: .contentProcessed { [weak self] _ in self?.close(connection) })
    }
}
