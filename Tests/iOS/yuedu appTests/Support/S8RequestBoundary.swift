import Foundation
import CryptoKit

/// 只装在S8隔离URLSession中：task delegate可能覆盖Session重定向策略，故在协议分派前拒绝未预审请求。
/// 允许的HTTP请求仍交给系统协议，不代理、不重写响应，也不接管WebKit资源。
final class S8RequestBoundary: @unchecked Sendable {
    private static let registryLock = NSLock()
    // 实源只准入这些公共传输头；不能只枚举Cookie/Authorization而漏掉自定义认证头。
    private static let publicHeaderNames: Set<String> = [
        "user-agent", "accept", "accept-language", "accept-encoding", "accept-charset",
        "cache-control", "pragma", "range", "if-range", "if-none-match", "if-modified-since",
        "referer", "origin", "host", "connection", "content-length", "content-type", "upgrade-insecure-requests"
    ]
    // URLProtocol类方法没有Session实例；测试严格串行，且所有注册/读取均由registryLock保护。
    nonisolated(unsafe) private static weak var active: S8RequestBoundary?
    private let lock = NSLock()
    private var urls: Set<URL>
    private let approvedURLHashes: Set<String>
    private let maximumApprovals: Int
    private let allowsHead: Bool
    private let approvedDynamicURL: (@Sendable (URL) -> Bool)?
    private var approvals = 0
    private var rejections = 0

    enum Failure: Error { case overlappingBoundary }

    init(urls: [URL], maximumRequests: Int, approvedURLHashes: Set<String> = [], allowsHead: Bool = false,
         approvedDynamicURL: (@Sendable (URL) -> Bool)? = nil) throws {
        precondition((1...8).contains(maximumRequests))
        self.urls = Set(urls.map(Self.networkURL))
        self.approvedURLHashes = approvedURLHashes
        maximumApprovals = maximumRequests
        self.allowsHead = allowsHead
        self.approvedDynamicURL = approvedDynamicURL
        try Self.registryLock.withLock {
            guard Self.active == nil else { throw Failure.overlappingBoundary }
            Self.active = self
        }
    }

    func configure(_ configuration: URLSessionConfiguration) {
        configuration.protocolClasses = [S8RequestBoundaryProtocol.self] + (configuration.protocolClasses ?? [])
    }

    /// 调用方先检查协议、来源、凭据存储和预算，再显式准入下一页/选中的正文或单个资源。
    func admit(_ url: URL) {
        _ = lock.withLock { urls.insert(Self.networkURL(url)) }
    }

    func close() {
        Self.registryLock.withLock {
            if Self.active === self { Self.active = nil }
        }
    }

    var counts: (approved: Int, rejected: Int) { lock.withLock { (approvals, rejections) } }

    private static func networkURL(_ url: URL) -> URL {
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        parts.fragment = nil // fragment不是HTTP请求的一部分；不用于源/条目身份。
        return parts.url ?? url
    }

    private func contains(_ url: URL) -> Bool {
        let target = Self.networkURL(url)
        if urls.contains(target) { return true }
        let hash = SHA256.hash(data: Data(target.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined()
        return approvedURLHashes.contains(hash) || approvedDynamicURL?(target) == true
    }

    fileprivate static func rejects(_ request: URLRequest) -> Bool {
        guard let boundary = registryLock.withLock({ active }) else { return true }
        return boundary.lock.withLock {
            let credential = (request.allHTTPHeaderFields ?? [:]).keys.contains {
                !publicHeaderNames.contains($0.lowercased())
            }
            guard let url = request.url, ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
                  url.user == nil, url.password == nil,
                  (request.httpMethod ?? "GET").uppercased() == "GET"
                    || boundary.allowsHead && request.httpMethod?.uppercased() == "HEAD", request.httpBody == nil,
                  request.httpBodyStream == nil, !credential, boundary.contains(url),
                  boundary.approvals < boundary.maximumApprovals else {
                boundary.rejections += 1
                let approvedURL = request.url.map(networkURL)
                let knownTarget = approvedURL.map { boundary.contains($0) } ?? false
                let sameOrigin = boundary.urls.contains { $0.scheme == request.url?.scheme && $0.host == request.url?.host && $0.port == request.url?.port }
                let samePath = boundary.urls.contains { $0.path == request.url?.path }
                let reason = credential ? "credential" : knownTarget ? "budget-or-method" : "target"
                print("S8_BOUNDARY_REJECT reason=\(reason) approvals=\(boundary.approvals) sameOrigin=\(sameOrigin) samePath=\(samePath)")
                return true
            }
            // canInit若被系统重复询问，只会提前耗尽预算而拒绝，不会扩大实际请求上限。
            boundary.approvals += 1
            return false
        }
    }
}

private final class S8RequestBoundaryProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { S8RequestBoundary.rejects(request) }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        client?.urlProtocol(self, didFailWithError: NSError(domain: "S8RequestBoundary", code: 1))
    }
    override func stopLoading() { }
}
