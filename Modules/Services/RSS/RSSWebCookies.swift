import Foundation
import WebKit

/// 每个非持久WebKit空间的生命周期适配，不另存Cookie；持久/原生请求仍由CookieStore拥有。
@MainActor
final class RSSWebCookies: NSObject, WKHTTPCookieStoreObserver {
    private let store: WKHTTPCookieStore
    private var runtime: RSSRuntime?
    private var urls: [URL] = []
    private var baseline: [String: HTTPCookie] = [:]
    private var ownerID: String?
    private var sourceID: String?
    private var origin: String?
    private var credentialRevision: UInt64?
    private var explicitCookie: String?
    private var generation = 0
    private var operation: Task<Void, Error>?
    var onFailure: ((Error) -> Void)?

    init(_ store: WKHTTPCookieStore) { self.store = store }

    func bind(runtime: RSSRuntime, url: URL?, explicit: String?) async throws {
        generation &+= 1
        let id = generation
        let newOrigin = url.flatMap(SourceRequestHeaderScope.origin)
        let newCredentialRevision = LoginManager.shared.loginInfoRevision(sourceUrl: RSSRuntime.authenticationKey(for: runtime.source))
        let preserve = ownerID == runtime.owner?.runtimeIdentity && sourceID == runtime.source.id
            && origin == newOrigin && credentialRevision == newCredentialRevision
        if !preserve { store.remove(self) }
        self.runtime = runtime
        self.ownerID = runtime.owner?.runtimeIdentity
        self.sourceID = runtime.source.id
        self.origin = newOrigin
        credentialRevision = newCredentialRevision
        explicitCookie = explicit
        urls = url.map { [$0] } ?? []
        let previous = operation
        let work = Task { [self] in
            if let previous { _ = await previous.result }
            try Task.checkCancellation()
            guard id == generation, runtime.state.isCurrent else { throw CancellationError() }
            let existing = await store.allCookies()
            if !preserve {
                for cookie in existing { await store.deleteCookie(cookie) }
            }
            let seed = await Self.seed(url: url, explicit: explicit)
            try Task.checkCancellation()
            guard id == generation, runtime.state.isCurrent else { throw CancellationError() }
            let current = Dictionary(existing.filter { Self.allowed($0, for: urls) }.map { (Self.key($0), $0) }, uniquingKeysWith: { _, new in new })
            for cookie in seed where current[Self.key(cookie)] != cookie { await store.setCookie(cookie) }
            guard id == generation, runtime.state.isCurrent else { throw CancellationError() }
            let all = await store.allCookies()
            baseline = Dictionary(all.filter { Self.allowed($0, for: urls) }.map { (Self.key($0), $0) }, uniquingKeysWith: { _, new in new })
            store.add(self)
        }
        operation = work
        try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
    }

    func flush() async throws {
        guard let runtime else { return }
        let id = generation
        let previous = operation
        let work = Task { [self] in
            if let previous { try await previous.value }
            try Task.checkCancellation()
            guard id == generation, runtime.state.isCurrent else { throw CancellationError() }
            let cookies = await store.allCookies()
            guard id == generation, runtime.state.isCurrent else { throw CancellationError() }
            let allowed = cookies.filter { Self.allowed($0, for: urls) }
            guard allowed.count <= 256 else { throw RSSWebFailure.resourceUnavailable }
            let current = Dictionary(allowed.map { (Self.key($0), $0) }, uniquingKeysWith: { _, new in new })
            let removed = baseline.filter { current[$0.key] == nil }.map(\.value)
            let changed = current.filter { key, cookie in
                guard let old = baseline[key] else { return true }
                return cookie.value != old.value || cookie.expiresDate != old.expiresDate
                    || cookie.isSecure != old.isSecure || cookie.isHTTPOnly != old.isHTTPOnly
            }.map(\.value)
            if !changed.isEmpty || !removed.isEmpty {
                try await SourceScriptThread.run {
                    guard runtime.state.isCurrent else { throw CancellationError() }
                    try CookieStore.shared.synchronizeWebCookies(changed, removed: removed, authorization: runtime.state)
                }
            }
            guard id == generation, runtime.state.isCurrent else { throw CancellationError() }
            baseline = current
        }
        operation = work
        try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
    }

    /// 原生图片响应的Set-Cookie也须到达WebKit。只合并Native增量，不覆盖尚未提交的网页Cookie。
    func synchronizeFromNative() async throws {
        try await flush()
        guard let runtime, let url = urls.first else { return }
        let id = generation, previous = operation, explicit = explicitCookie
        let work = Task { [self] in
            if let previous { try await previous.value }
            try Task.checkCancellation()
            guard id == generation, runtime.state.isCurrent else { throw CancellationError() }
            let seed = await Self.seed(url: url, explicit: explicit, preferExplicit: false)
            let existing = await store.allCookies()
            guard id == generation, runtime.state.isCurrent else { throw CancellationError() }
            let current = Dictionary(existing.filter { Self.allowed($0, for: urls) }.map { (Self.key($0), $0) }, uniquingKeysWith: { _, new in new })
            let native = Dictionary(seed.map { (Self.key($0), $0) }, uniquingKeysWith: { _, new in new })
            var expected = baseline
            for (key, cookie) in baseline where native[key] == nil && Self.same(current[key], cookie) {
                await store.deleteCookie(cookie); expected[key] = nil
            }
            for (key, cookie) in native where !Self.same(cookie, baseline[key]) && Self.same(current[key], baseline[key]) {
                await store.setCookie(cookie); expected[key] = cookie
            }
            guard id == generation, runtime.state.isCurrent else { throw CancellationError() }
            // 记录本次真正写入的值，不把等待IPC期间的JS修改误记为已经同步。
            baseline = expected
        }
        operation = work
        try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
    }
    private static func same(_ lhs: HTTPCookie?, _ rhs: HTTPCookie?) -> Bool {
        guard let lhs, let rhs else { return lhs == nil && rhs == nil }
        return lhs.value == rhs.value && lhs.expiresDate == rhs.expiresDate
            && lhs.isSecure == rhs.isSecure && lhs.isHTTPOnly == rhs.isHTTPOnly
    }

    func reset() {
        generation &+= 1
        let id = generation
        store.remove(self)
        runtime = nil
        urls = []
        ownerID = nil
        sourceID = nil
        origin = nil
        credentialRevision = nil
        explicitCookie = nil
        baseline = [:]
        let previous = operation
        operation = Task { [self] in
            if let previous { _ = await previous.result }
            guard id == generation else { return }
            for cookie in await store.allCookies() { await store.deleteCookie(cookie) }
        }
    }

    nonisolated func cookiesDidChange(in cookieStore: WKHTTPCookieStore) {
        Task { @MainActor [weak self] in
            guard let self, self.runtime?.state.isCurrent == true else { return }
            do { try await self.flush() }
            catch is CancellationError { }
            catch { self.onFailure?(error) }
        }
    }

    private nonisolated static func key(_ cookie: HTTPCookie) -> String {
        RSSIdentity.digest([cookie.domain, cookie.path, cookie.name])
    }
    private nonisolated static func allowed(_ cookie: HTTPCookie, for urls: [URL]) -> Bool {
        let domain = cookie.domain.lowercased()
        let plain = domain.hasPrefix(".") ? String(domain.dropFirst()) : domain
        return urls.contains { url in
            guard let host = url.host?.lowercased() else { return false }
            return host == plain || domain.hasPrefix(".") && host.hasSuffix("." + plain)
        }
    }
    private nonisolated static func seed(url: URL?, explicit: String?, preferExplicit: Bool = true) async -> [HTTPCookie] {
        guard let url, let host = url.host else { return [] }
        var cookies = CookieStore.shared.webCookies(for: url)
        if let explicit {
            for segment in explicit.split(separator: ";") {
                let parts = segment.trimmingCharacters(in: .whitespaces).split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                guard parts.count == 2, !parts[0].isEmpty else { continue }
                var properties: [HTTPCookiePropertyKey: Any] = [.domain: host, .path: "/", .name: String(parts[0]), .value: String(parts[1])]
                if url.scheme == "https" { properties[.secure] = "TRUE" }
                guard let cookie = HTTPCookie(properties: properties) else { continue }
                if !preferExplicit, cookies.contains(where: { $0.domain == cookie.domain && $0.path == cookie.path && $0.name == cookie.name }) { continue }
                cookies.removeAll { $0.domain == cookie.domain && $0.path == cookie.path && $0.name == cookie.name }
                cookies.append(cookie)
            }
        }
        return cookies
    }
}

private extension WKHTTPCookieStore {
    func allCookies() async -> [HTTPCookie] {
        await withCheckedContinuation { continuation in getAllCookies { continuation.resume(returning: $0) } }
    }
}
