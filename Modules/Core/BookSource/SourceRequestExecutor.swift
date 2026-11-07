import Foundation

/// 只约束隐式继承的源认证头。URL options / java.*显式传入的头仍属于那一次目标请求。
final class SourceRequestHeaderScope: @unchecked Sendable {
    private let lock = NSLock()
    private var origins: Set<String>
    static let publicHeaderNames: Set<String> = [
        "user-agent", "accept", "accept-language", "accept-encoding", "content-type",
        "range", "cache-control", "pragma"
    ]

    init(urls: [URL]) { origins = Set(urls.compactMap(Self.origin)) }
    func admitPrimaryURL(_ url: URL) {
        guard let origin = Self.origin(url) else { return }
        _ = lock.withLock { origins.insert(origin) }
    }
    func inheritedHeaders(_ headers: [String: String], for url: URL?) -> [String: String] {
        let allowed = url.flatMap(Self.origin).map { origin in lock.withLock { origins.contains(origin) } } ?? false
        return allowed ? headers : headers.filter { Self.publicHeaderNames.contains($0.key.lowercased()) }
    }
    static func origin(_ url: URL) -> String? {
        guard let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = url.host?.lowercased() else { return nil }
        return "\(scheme)://\(host):\(url.port ?? (scheme == "https" ? 443 : 80))"
    }
}

/// 原生请求和java.*共用的网络边界。构造/脚本仍在原AnalyzeUrl；此处只处理执行、限流、Cookie与重定向。
struct SourceRequestExecutor: Sendable {
    let session: URLSession
    let rate: String
    let rateKey: String
    let cookieJarEnabled: Bool?
    var runtimeState: (any SourceRuntimeStateAccess)? = nil

    func data(for raw: URLRequest) async throws -> (Data, URLResponse) {
        guard runtimeState?.isCurrent != false else { throw CancellationError() }
        var request = raw
        let redirect: SourceRequestRedirectGuard?
        if let cookieJarEnabled {
            guard let url = raw.url, SourceRequestHeaderScope.origin(url) != nil,
                  url.user == nil, url.password == nil else { throw URLError(.unsupportedURL) }
            let explicitCookie = raw.value(forHTTPHeaderField: "Cookie")
            request.httpShouldHandleCookies = cookieJarEnabled
            Self.applyRequestCookies(to: &request, explicit: explicitCookie)
            redirect = SourceRequestRedirectGuard(initialURL: url, explicitCookie: explicitCookie, cookieJarEnabled: cookieJarEnabled)
        } else { redirect = nil }
        let configuredRequest = request
        let timeout = min(30, max(1, request.timeoutInterval))
        let work = Task { () throws -> (Data, URLResponse) in
          try await SourceRateLimit.run(rate: rate, key: rateKey) {
            try Task.checkCancellation()
            guard runtimeState?.isCurrent != false else { throw CancellationError() }
            return try await withThrowingTaskGroup(of: (Data, URLResponse).self) { group -> (Data, URLResponse) in
                group.addTask { try await session.data(for: configuredRequest, delegate: redirect) }
                group.addTask {
                    try await Task.sleep(for: .seconds(timeout))
                    throw URLError(.timedOut)
                }
                defer { group.cancelAll() }
                guard let result = try await group.next() else { throw CancellationError() }
                return result
            }
          }
        }
        let token = runtimeState?.addCancellation { work.cancel() }
        defer { if let token { runtimeState?.removeCancellation(token) } }
        return try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
    }

    fileprivate static func applyRequestCookies(to request: inout URLRequest, explicit: String?) {
        guard let url = request.url else { return }
        let jar = CookieStore.shared.requestHeader(for: url)
        let merged = CookieStore.shared.merge(existing: jar, incoming: explicit ?? "")
        request.setValue(merged.isEmpty ? nil : merged, forHTTPHeaderField: "Cookie")
    }
}

private final class SourceRequestRedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    let initialURL: URL
    let explicitCookie: String?
    let cookieJarEnabled: Bool
    init(initialURL: URL, explicitCookie: String?, cookieJarEnabled: Bool) {
        self.initialURL = initialURL
        self.explicitCookie = explicitCookie
        self.cookieJarEnabled = cookieJarEnabled
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard let url = request.url, let target = SourceRequestHeaderScope.origin(url),
              url.user == nil, url.password == nil else { completionHandler(nil); return }
        var redirected = request
        let sameOrigin = target == SourceRequestHeaderScope.origin(initialURL)
        if !sameOrigin {
            for key in (redirected.allHTTPHeaderFields ?? [:]).keys where !SourceRequestHeaderScope.publicHeaderNames.contains(key.lowercased()) {
                redirected.setValue(nil, forHTTPHeaderField: key)
            }
        }
        // 原路径的jar Cookie不能复用到新路径，即使host没变；跨origin更不能带原始手工Cookie。
        redirected.httpShouldHandleCookies = cookieJarEnabled
        SourceRequestExecutor.applyRequestCookies(to: &redirected, explicit: sameOrigin ? explicitCookie : nil)
        completionHandler(redirected)
    }
}
