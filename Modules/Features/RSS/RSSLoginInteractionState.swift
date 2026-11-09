import Foundation
import Observation

/// 前台 RSS 源登录期间，与共享脚本会话阻塞的 startBrowserAwait / getVerificationCode 对接。
@MainActor @Observable final class RSSLoginInteractionState {
    struct Browser: Identifiable {
        let id = UUID()
        var target: RSSOpenTarget
        var title: String
        var awaitsResult: Bool
        var context: RSSOpenTarget.RequestContext?
    }
    struct Captcha: Identifiable {
        let id = UUID()
        var request: SourceCaptchaRequest
    }
    var browser: Browser?
    var captcha: Captcha?
    var generation = 0
    var completion: (@Sendable (String?) -> Void)?
    var captchaCompletion: (@Sendable (String?) -> Void)?
    var error: String?

    func present(_ request: SourceBrowserRequest, runtime: RSSRuntime, completion: @escaping @Sendable (String?) -> Void) {
        guard let url = request.urlRequest?.url ?? URL(string: request.url) else { completion(nil); return }
        let target: RSSOpenTarget
        let requestValue: URLRequest
        if let html = request.html {
            target = .articleHTML(html, baseURL: url.absoluteString)
            requestValue = request.urlRequest ?? URLRequest(url: url)
        } else if let prepared = request.urlRequest {
            target = .request(prepared, context: nil)
            requestValue = prepared
        } else { completion(nil); return }
        let prepared = SourcePreparedWebRequest(request: requestValue, responseOptions: .init(), variables: [:])
        let context = RSSOpenTarget.RequestContext(prepared, runtime: runtime)
        generation &+= 1
        browser = .init(target: target, title: String(request.title.prefix(256)), awaitsResult: request.awaitsResult, context: context)
        self.completion = request.awaitsResult ? completion : nil
    }
    func present(_ request: LegadoBrowserPageRequest, source: RSSSource, runtime: RSSRuntime?) {
        guard let url = URL(string: request.baseURL), SourceRequestHeaderScope.origin(url) != nil else { return }
        generation &+= 1
        guard let html = request.html else { error = RSSWebFailure.actionUnavailable.localizedDescription; return }
        let prepared = SourcePreparedWebRequest(request: URLRequest(url: url), responseOptions: .init(), variables: [:])
        browser = .init(target: .articleHTML(html, baseURL: url.absoluteString), title: source.name, awaitsResult: false,
                        context: runtime.map { RSSOpenTarget.RequestContext(prepared, runtime: $0) })
        if !request.injectedJavaScript.isEmpty || request.configurationJSON != "{}" {
            error = localized("此網頁操作尚不支援")
        }
    }
    func finish(_ value: String?) {
        let callback = completion
        completion = nil
        browser = nil
        callback?(value)
    }
    func present(_ request: SourceCaptchaRequest, completion: @escaping @Sendable (String?) -> Void) {
        generation &+= 1
        captcha = .init(request: request)
        captchaCompletion = completion
    }
    func finishCaptcha(_ value: String?) {
        let callback = captchaCompletion
        captchaCompletion = nil
        captcha = nil
        callback?(value)
    }
    func cancel() {
        generation &+= 1
        finish(nil); finishCaptcha(nil)
    }
}
