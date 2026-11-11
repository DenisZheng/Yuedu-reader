import SwiftUI
import Testing
import UIKit
import WebKit
@testable import yuedu_app

/// 自建标准HTML经生产首文档路径加载；按钮越界必须靠显示控制解决，不能删除网页脚本。
@Suite("RSS web display viewport", .serialized)
@MainActor
struct RSSWebViewportTests {
    @Observable final class Display {
        var percent = 100
        var loading = true
        var error: String?
    }

    private struct Page: View {
        let display: Display
        let source: RSSSource
        let target: RSSOpenTarget
        var body: some View {
            RSSSourcePageWebView(source: source, target: target,
                error: Binding(get: { display.error }, set: { display.error = $0 }),
                loading: Binding(get: { display.loading }, set: { display.loading = $0 }),
                displayScalePercent: display.percent)
        }
    }

    @Test("标准模式超大固定弹层缩小后可关闭，保留脚本开关且不重新请求", arguments: [true, false])
    func requestDocumentZoom(scripts: Bool) async throws {
        let directory = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let server = try VideoStillFixtureServer(directory: directory, routes: [
            "/page": .init(body: Data(Self.html.utf8), type: "text/html")
        ])
        let base = try await server.start()
        defer {
            server.stop()
            do { try FileManager.default.removeItem(at: directory) } catch { Issue.record(error) }
        }
        var source = RSSSource(name: "Viewport fixture", url: base.absoluteString)
        source.enableJs = scripts
        let display = Display()
        let window = try host(Page(display: display, source: source,
            target: .request(URLRequest(url: base.appendingPathComponent("page")))))
        defer { window.isHidden = true; window.rootViewController = nil }
        let web = try await webView(in: window, display: display)
        #expect(display.error == nil)
        #expect(try await web.evaluateJavaScript("document.compatMode") as? String == "CSS1Compat")
        #expect(try await web.evaluateJavaScript(Self.buttonVisible) as? Bool == false, "原始弹层的关闭按钮确实越界")
        let requests = server.requests.count
        display.percent = 10
        try await eventually("缩小后关闭按钮进入可视视口") {
            try await web.evaluateJavaScript(Self.buttonVisible) as? Bool == true
        }
        #expect(display.error == nil)
        #expect(server.requests.count == requests, "缩放不能重发首文档请求")
        #expect(try await web.evaluateJavaScript("window.runs || 0") as? Int == (scripts ? 1 : 0))
        #expect(web.configuration.defaultWebpagePreferences.allowsContentJavaScript == scripts)
        _ = try await web.evaluateJavaScript("document.getElementById('close-panel').click()")
        #expect(try await web.evaluateJavaScript("document.getElementById('panel').hidden") as? Bool == scripts)
        display.percent = 100
        try await eventually("100%恢复作者的viewport原文") {
            try await web.evaluateJavaScript("document.querySelector('meta[name=viewport]').content") as? String == Self.viewport
        }
        #expect(server.requests.count == requests)
    }

    @Test("恢复缺失/多重viewport原属性，拒绝迟到修订且快照不暴露给页面", arguments: [false, true])
    func restoreAndRevision(hasViewport: Bool) async throws {
        let meta = hasViewport ? "<meta name='viewport' content='width=device-width,initial-scale=1'><meta name='VIEWPORT'>" : ""
        let display = Display()
        let window = try host(Page(display: display, source: RSSSource(name: "Metadata", url: "https://viewport-fixture.invalid/"),
            target: .html("<!doctype html><html><head>\(meta)<style>body{margin:0}</style></head><body>Fixture</body></html>",
                          baseURL: "https://viewport-fixture.invalid/")))
        defer { window.isHidden = true; window.rootViewController = nil }
        let web = try await webView(in: window, display: display)
        let metadata = "JSON.stringify(Array.from(document.querySelectorAll('meta[name=viewport i]')).map(n=>[n.getAttribute('name'),n.getAttribute('content')]))"
        let original = try await web.evaluateJavaScript(metadata) as? String
        #expect(try await RSSWebViewport.apply(10, revision: 100, in: web))
        #expect(try await web.evaluateJavaScript(metadata) as? String != original)
        #expect(try await web.evaluateJavaScript("typeof window.__readerRSSDisplayViewport") as? String == "undefined")
        #expect(try await RSSWebViewport.apply(50, revision: 102, in: web))
        #expect(try await RSSWebViewport.apply(25, revision: 101, in: web) == false)
        #expect(try await web.evaluateJavaScript("document.querySelector('meta[name=viewport i]').content.includes('initial-scale=0.5')") as? Bool == true)
        #expect(try await RSSWebViewport.apply(100, revision: 103, in: web))
        #expect(try await web.evaluateJavaScript(metadata) as? String == original)
    }

    @Test("viewport超过预算时明确失败，不部分修改作者属性")
    func excessiveMetadata() async throws {
        let meta = String(repeating: "<meta name='viewport' content='width=device-width,initial-scale=1'>", count: 33)
        let display = Display()
        let window = try host(Page(display: display, source: RSSSource(name: "Budget", url: "https://viewport-budget.invalid/"),
            target: .html("<!doctype html><html><head>\(meta)<style>body{margin:0}</style></head><body>Fixture</body></html>",
                          baseURL: "https://viewport-budget.invalid/")))
        defer { window.isHidden = true; window.rootViewController = nil }
        let web = try await webView(in: window, display: display)
        let contents = "JSON.stringify(Array.from(document.querySelectorAll('meta[name=viewport]')).map(n=>n.content))"
        let original = try await web.evaluateJavaScript(contents) as? String
        do {
            _ = try await RSSWebViewport.apply(10, revision: 100, in: web)
            Issue.record("超出预算不能假装缩放成功")
        } catch { #expect(error is WKError) }
        #expect(try await web.evaluateJavaScript(contents) as? String == original)
    }

    static let viewport = "width=device-width, initial-scale=1, maximum-scale=1, user-scalable=no"
    static let html = """
    <!doctype html><html><head><meta name="viewport" content="\(viewport)">
    <style>body{margin:0}#panel{position:fixed;width:1300px;height:1800px;left:50%;top:50%;transform:translate(-50%,-50%);background:#ddd}
    #close-panel{position:absolute;right:16px;top:16px;min-width:44px;height:44px}</style>
    <script>window.runs=(window.runs||0)+1</script></head><body>
    <p>Fixture article</p><div id="panel"><button id="close-panel" onclick="document.getElementById('panel').hidden=true">Close panel</button></div>
    </body></html>
    """
    static let buttonVisible = """
    (()=>{const r=document.getElementById('close-panel').getBoundingClientRect(),v=window.visualViewport;
    return r.left>=v.offsetLeft && r.right<=v.offsetLeft+v.width && r.top>=v.offsetTop && r.bottom<=v.offsetTop+v.height})()
    """

    private func host(_ view: some View) throws -> UIWindow {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: view)
        window.makeKeyAndVisible()
        return window
    }

    private func webView(in window: UIWindow, display: Display) async throws -> WKWebView {
        func find(_ view: UIView) -> WKWebView? { (view as? WKWebView) ?? view.subviews.lazy.compactMap(find).first }
        try await eventually("生产首文档加载完成") { find(window) != nil && !display.loading }
        return try #require(find(window))
    }

    private func eventually(_ label: String, _ predicate: () async throws -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline {
            if try await predicate() { return }
            await Task.yield()
        }
        #expect(try await predicate(), "等待失败：\(label)")
    }
}
