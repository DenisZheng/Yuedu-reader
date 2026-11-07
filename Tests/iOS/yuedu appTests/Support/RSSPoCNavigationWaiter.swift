import WebKit
import XCTest

/// 共享PoC导航等待器。超时/进程终止必须失败，不继续拿旧DOM冒充新页面结果。
@MainActor
final class RSSPoCNavigationWaiter: NSObject, WKNavigationDelegate {
    private var finished: XCTestExpectation?
    private var failure: Error?

    func load(_ start: () -> WKNavigation?) async throws {
        precondition(finished == nil, "同一WebView不能并发等待两次导航")
        let done = XCTestExpectation(description: "WKWebView完成或明确失败")
        finished = done
        failure = nil
        defer { finished = nil }
        guard start() != nil else { throw URLError(.badURL) }
        guard await XCTWaiter.fulfillment(of: [done], timeout: 10) == .completed else {
            throw URLError(.timedOut)
        }
        if let failure { throw failure }
    }

    private func finish(_ error: Error? = nil) {
        failure = error
        finished?.fulfill()
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finish() }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { finish(error) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { finish(error) }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { finish(URLError(.networkConnectionLost)) }
}
