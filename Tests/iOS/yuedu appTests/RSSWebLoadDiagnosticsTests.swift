import SwiftUI
import Testing
import UIKit
import WebKit
@testable import yuedu_app

/// 验证私有头/响应规则所需的原生路径仍保留失败诊断；不连接外部站点。
@Suite("RSS web load diagnostic boundary", .serialized)
@MainActor
struct RSSWebLoadDiagnosticsTests {
    @Test("原生首文档失败留下状态与阶段，不泄露响应且不增加自动重试")
    func recordsNativeDocumentFailure() async throws {
        let secret = "fixture-only-private-value"
        let server = try VideoStillFixtureServer(directory: .temporaryDirectory, routes: [
            "/page": .init(body: Data("<p>\(secret)</p>".utf8), type: "text/html", status: "503 Service Unavailable")
        ])
        let base = try await server.start()
        defer { server.stop() }
        let url = try #require(URL(string: base.appendingPathComponent("page").absoluteString + "?key=" + secret))
        var source = RSSSource(name: secret, url: url.absoluteString)
        source.singleUrl = true
        source.enabledCookieJar = true
        source.cacheFirst = false
        source.enableJs = false
        source.header = "{\"X-Fixture\":\"\(secret)\"}"
        let target = try #require(try await RSSOpenTarget.resolve(source: source))
        var loading = true
        var error: String?
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: RSSSourcePageWebView(source: source, target: target,
            error: Binding(get: { error }, set: { error = $0 }), loading: Binding(get: { loading }, set: { loading = $0 })))
        window.isHidden = false
        defer { window.isHidden = true; window.rootViewController = nil }
        let deadline = ContinuousClock.now + .seconds(8)
        while loading, ContinuousClock.now < deadline { await Task.yield() }
        try #require(!loading && error != nil, "自建503必须真正走到生产网页失败分支")
        #expect(server.requests.count == 1, "补诊断不应增加任何隐式网络重试")
        let sourceTag = String(RSSIdentity.digest([source.id]).prefix(16))
        let messages = await Task.detached(priority: .utility) {
            DiagnosticLog.shared.snapshot().map(\.message)
                .filter { $0.contains("[RSSWebLoad]") && $0.contains("source=" + sourceTag) }
        }.value
        #expect(messages.contains { $0.contains("event=failed") && $0.contains("phase=document") && $0.contains("httpStatus=503") })
        #expect(messages.allSatisfy { !$0.contains(secret) && !$0.contains(base.absoluteString) && !$0.contains("<p>") })
    }

    @Test("系统网络错误只保留域和码，错误文案中的HTTP404不能被当作真实HTTP状态",
          arguments: [-1001, -1003, -1005, -1200, -1202, -1022])
    func systemErrorRedaction(_ code: Int) {
        let secret = "fixture-secret-cookie-body"
        let source = RSSSource(name: secret, url: "https://\(secret).invalid/private?token=\(secret)")
        let underlying = NSError(domain: "kCFErrorDomainCFNetwork", code: -9807,
                                 userInfo: [NSLocalizedDescriptionKey: secret])
        let failure = NSError(domain: NSURLErrorDomain, code: code, userInfo: [
            NSLocalizedDescriptionKey: "HTTP404 \(secret)", NSUnderlyingErrorKey: underlying,
            NSURLErrorFailingURLStringErrorKey: source.url, "Cookie": secret, "body": secret
        ])
        let message = RSSWebLoadDiagnostics.Attempt(source: source).message(.failed, phase: .document, failure: failure)
        #expect(message.contains("domain=url") && message.contains("code=\(code)"))
        #expect(message.contains("underlying1.domain=cfnetwork") && message.contains("underlying1.code=-9807"))
        #expect(!message.contains(secret) && !message.contains("httpStatus=") && !message.contains("HTTP404"))
    }

    @Test("未知错误域、规则载荷和过深错误链不会泄露或无限展开")
    func unknownAndNestedErrors() {
        let secret = "fixture-secret-domain"
        let source = RSSSource(name: secret, url: "https://example.invalid/?secret=" + secret)
        let attempt = RSSWebLoadDiagnostics.Attempt(source: source)
        let unknown = attempt.message(.failed, phase: .document,
            failure: NSError(domain: secret, code: 987654321, userInfo: [NSLocalizedDescriptionKey: secret]))
        #expect(unknown.contains("domain=other") && !unknown.contains(secret) && !unknown.contains("987654321"))
        let script = attempt.message(.failed, phase: .scripts, failure: ScraperError.invalidRule(secret))
        #expect(script.contains("kind=invalidRule") && !script.contains(secret))
        var chain = NSError(domain: NSURLErrorDomain, code: -1005)
        for _ in 0..<8 { chain = NSError(domain: NSURLErrorDomain, code: -1005, userInfo: [NSUnderlyingErrorKey: chain]) }
        let message = attempt.message(.failed, phase: .document, failure: chain)
        #expect(message.contains("underlying2.code=-1005") && !message.contains("underlying3"))
    }

    @Test("WebKit崩溃和真实HTTP错误分开，重试拥有不同尝试ID")
    func typedFailuresAndAttemptIdentity() {
        let source = RSSSource(name: "Fixture", url: "https://example.invalid/")
        let first = RSSWebLoadDiagnostics.Attempt(source: source)
        let second = RSSWebLoadDiagnostics.Attempt(source: source)
        #expect(first.id != second.id && first.source == second.source && first.key == second.key)
        let web = first.message(.failed, phase: .webProcess, failure: WKError(.webContentProcessTerminated))
        #expect(web.contains("domain=webkit") && web.contains("code=2") && !web.contains("httpStatus="))
        let http = first.message(.failed, phase: .document, failure: ScraperError.httpStatus(503))
        #expect(http.contains("httpStatus=503") && http.contains("kind=httpStatus"))
    }
}
