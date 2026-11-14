import UIKit
import WebKit
import XCTest
@testable import yuedu_app

/// S1平台约束实验。页面/脚本全部自行构造，只访问本机固定路由，不使用真实源或账号。
@MainActor
final class RSSWebResourcePoCTests: XCTestCase {
    private let fixtures = VideoStillFixtures.directory()

    func testPageScriptsRelativeResourcesAndMainFrameInjectionOrder() async throws {
        let server = try VideoStillFixtureServer(directory: fixtures, routes: [
            "/page": .init(body: Data("""
                <html><head><link rel="stylesheet" href="/style.css"><script src="/script.js"></script></head>
                <body><img id="image" src="/pixel"><iframe id="child" src="/frame"></iframe></body></html>
                """.utf8)),
            "/style.css": .init(body: Data("body { background-color: rgb(12,34,56); }".utf8), type: "text/css"),
            "/script.js": .init(body: Data("window.fixtureOrder.push('page')".utf8), type: "application/javascript"),
            "/pixel": .init(body: pixel(), type: "image/png"),
            "/frame": .init(body: Data("<script>window.frameExecuted=true</script>".utf8))
        ])
        let base = try await server.start()
        defer { server.stop() }
        let configuration = configuration()
        configuration.userContentController.addUserScript(WKUserScript(
            source: "window.fixtureOrder=['preload']", injectionTime: .atDocumentStart, forMainFrameOnly: true))
        let page = try RSSPoCWebPage(configuration: configuration)
        defer { page.close() }
        for _ in 0..<2 {
            try await page.waiter.load { page.view.load(URLRequest(url: base.appendingPathComponent("page"))) }
            // injectJs对应页面完成阶段，不以documentEnd冒充所有子资源完成。
            _ = try await page.view.evaluateJavaScript("window.fixtureOrder.push('finished')")
            let result = try await page.view.evaluateJavaScript("""
                ({ order: window.fixtureOrder.join(','), image: document.getElementById('image').naturalWidth,
                   background: getComputedStyle(document.body).backgroundColor,
                   childExecuted: document.getElementById('child').contentWindow.frameExecuted,
                   childWasInjected: !!document.getElementById('child').contentWindow.fixtureOrder })
                """) as? [String: Any]
            XCTAssertEqual(result?["order"] as? String, "preload,page,finished")
            XCTAssertEqual(result?["image"] as? Int, 1)
            XCTAssertEqual(result?["background"] as? String, "rgb(12, 34, 56)")
            XCTAssertEqual(result?["childExecuted"] as? Bool, true)
            XCTAssertEqual(result?["childWasInjected"] as? Bool, false)
        }
        XCTAssertTrue(Set(server.requests.map(\.path)).isSuperset(of: ["/page", "/pixel", "/style.css", "/script.js", "/frame"]))
    }

    func testDisabledContentJavaScriptDoesNotExecutePageOrFrameScripts() async throws {
        let server = try VideoStillFixtureServer(directory: fixtures, routes: [
            "/page": .init(body: Data("<script>window.ran=true</script><iframe id='child' src='/frame'></iframe>".utf8)),
            "/frame": .init(body: Data("<script>window.ran=true</script>".utf8))
        ])
        let base = try await server.start()
        defer { server.stop() }
        let config = configuration()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        let page = try RSSPoCWebPage(configuration: config)
        defer { page.close() }
        try await page.waiter.load { page.view.load(URLRequest(url: base.appendingPathComponent("page"))) }
        let result = try await page.view.evaluateJavaScript("!window.ran && !document.getElementById('child').contentWindow.ran") as? Bool
        XCTAssertEqual(result, true)
        XCTAssertTrue(server.requests.contains { $0.path == "/frame" })
    }

    func testHTMLBaseURLControlsRelativeImageLoading() async throws {
        let server = try VideoStillFixtureServer(directory: fixtures, routes: ["/pixel": .init(body: pixel(), type: "image/png")])
        let base = try await server.start()
        defer { server.stop() }
        let page = try RSSPoCWebPage(configuration: configuration())
        defer { page.close() }
        let html = "<html><body><img id='image' src='pixel'></body></html>"
        try await page.waiter.load { page.view.loadHTMLString(html, baseURL: base) }
        let loaded = try await page.view.evaluateJavaScript("document.getElementById('image').naturalWidth") as? Int
        XCTAssertEqual(loaded, 1)
        XCTAssertEqual(server.requests.filter { $0.path == "/pixel" }.count, 1)
        try await page.waiter.load { page.view.loadHTMLString(html, baseURL: nil) }
        let absent = try await page.view.evaluateJavaScript("document.getElementById('image').naturalWidth") as? Int
        XCTAssertEqual(absent, 0)
        XCTAssertEqual(server.requests.filter { $0.path == "/pixel" }.count, 1)
    }

    func testCookieHostPathAndLogoutReachActualImageRequests() async throws {
        let image = pixel()
        let remote = try VideoStillFixtureServer(directory: fixtures, routes: ["/private/pixel": .init(body: image, type: "image/png")])
        let remoteBase = try await remote.start()
        defer { remote.stop() }
        var remoteParts = try XCTUnwrap(URLComponents(url: remoteBase, resolvingAgainstBaseURL: false))
        remoteParts.host = "localhost"
        let remoteURL = try XCTUnwrap(remoteParts.url).appendingPathComponent("private/pixel")
        let server = try VideoStillFixtureServer(directory: fixtures, routes: [
            "/page": .init(body: Data("<img id='private' src='/private/pixel'><img id='public' src='/public/pixel'><img src='\(remoteURL.absoluteString)'>".utf8)),
            "/private/pixel": .init(body: image, type: "image/png", requiredHeaders: ["cookie": "fixture_session=synthetic"]),
            "/public/pixel": .init(body: image, type: "image/png")
        ])
        let base = try await server.start()
        defer { server.stop() }
        let config = configuration()
        let cookie = try XCTUnwrap(HTTPCookie(properties: [.domain: "127.0.0.1", .path: "/private/", .name: "fixture_session", .value: "synthetic"]))
        await config.websiteDataStore.httpCookieStore.setCookie(cookie)
        let page = try RSSPoCWebPage(configuration: config)
        defer { page.close() }
        try await page.waiter.load { page.view.load(URLRequest(url: base.appendingPathComponent("page"))) }
        let loaded = try await page.view.evaluateJavaScript("document.getElementById('private').naturalWidth") as? Int
        XCTAssertEqual(loaded, 1)
        XCTAssertEqual(server.requests.first { $0.path == "/private/pixel" }?.headers["cookie"], "fixture_session=synthetic")
        XCTAssertTrue(server.requests.filter { $0.path == "/public/pixel" || $0.path == "/page" }.allSatisfy { $0.headers["cookie"] == nil })
        XCTAssertFalse(remote.requests.isEmpty)
        XCTAssertTrue(remote.requests.allSatisfy { $0.headers["cookie"] == nil })
        let before = server.requests.count
        await config.websiteDataStore.httpCookieStore.deleteCookie(cookie)
        try await page.waiter.load { page.view.load(URLRequest(url: base.appendingPathComponent("page"))) }
        let denied = try await page.view.evaluateJavaScript("document.getElementById('private').naturalWidth") as? Int
        XCTAssertEqual(denied, 0)
        let afterLogout = Array(server.requests.dropFirst(before))
        XCTAssertTrue(afterLogout.contains { $0.path == "/private/pixel" })
        XCTAssertTrue(afterLogout.allSatisfy { $0.headers["cookie"] == nil })
    }

    func testWebMP4DynamicURLActuallyPlays() async throws { try await playWebMedia("video-still-landscape.mp4", inFrame: false) }
    func testWebHLSDynamicURLActuallyPlaysInsideIframe() async throws { try await playWebMedia("video-still-hls.m3u8", inFrame: true) }

    func testPublicWebKitBoundariesBlockUnknownSubresourcesButCannotCountRequests() async throws {
        let server = try VideoStillFixtureServer(directory: fixtures, routes: [
            "/page": .init(body: Data("<script>window.boundaryResult = new Promise(resolve => addEventListener('message', event => resolve(event.data), {once:true}));</script><iframe id='child'></iframe>".utf8)),
            "/frame": .init(body: Data("""
                <iframe id="nested" src="/nested-frame"></iframe>
                <img id="unknown-image" src="/unreviewed-image">
                <script>
                window.runBoundaryProbe = async function() {
                    const image = document.getElementById('unknown-image');
                    const imageWidth = await new Promise(resolve => {
                        if (image.complete) resolve(image.naturalWidth);
                        else { image.onload = () => resolve(image.naturalWidth); image.onerror = () => resolve(0); }
                    });
                    const approved = [];
                    for (let i = 0; i < 2; i++) {
                        const response = await fetch('/pixel?approved=1', {cache:'no-store'});
                        approved.push(response.status);
                        await response.arrayBuffer();
                    }
                    const unknownFetchBlocked = await fetch('/unreviewed-fetch', {cache:'no-store'}).then(() => false, () => true);
                    const redirectBlocked = await fetch('/redirect-pixel', {cache:'no-store'}).then(() => false, () => true);
                    parent.postMessage({imageWidth, approved, unknownFetchBlocked, redirectBlocked}, '*');
                };
                addEventListener('load', () => window.runBoundaryProbe(), {once:true});
                </script>
                """.utf8)),
            "/nested-frame": .init(body: Data("<img src='/unreviewed-nested-image'>".utf8)),
            "/pixel": .init(body: Data("approved".utf8), type: "text/plain"),
            "/redirect-pixel": .init(body: Data(), status: "302 Found", headers: ["Location": "/denied-redirect-target"])
        ])
        let base = try await server.start()
        defer { server.stop() }
        let frameURL = try crossOriginLocalURL(base.appendingPathComponent("frame"))
        let nestedFrameURL = try crossOriginLocalURL(base.appendingPathComponent("nested-frame"))
        let pageURL = base.appendingPathComponent("page")
        let pageHTML = "<script>window.boundaryResult = new Promise(resolve => addEventListener('message', event => resolve(event.data), {once:true}));</script><iframe id='child' src='\(frameURL.absoluteString)'></iframe>"
        server.route { request in
            request.path == "/page" ? .init(body: Data(pageHTML.utf8)) : nil
        }
        let approvedImageFetch = try XCTUnwrap(URL(string: "/pixel?approved=1", relativeTo: frameURL)?.absoluteURL)
        let redirectFetch = frameURL.deletingLastPathComponent().appendingPathComponent("redirect-pixel")
        let contentStoreDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("s8-wk-resource-rules-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: contentStoreDirectory, withIntermediateDirectories: true)
        defer {
            do { try FileManager.default.removeItem(at: contentStoreDirectory) }
            catch { XCTFail("清理本次本地WebKit规则fixture失败") }
        }
        let contentStore = try XCTUnwrap(WKContentRuleListStore(url: contentStoreDirectory))
        let encoded = try denyLocalFixtureResourcesExcept([pageURL, frameURL, nestedFrameURL, approvedImageFetch, redirectFetch], port: XCTUnwrap(base.port))
        let ruleIdentifier = "s8-\(UUID().uuidString)"
        let rules = try await contentStore.compileContentRuleList(forIdentifier: ruleIdentifier, encodedContentRuleList: encoded)
        let configuration = configuration()
        configuration.userContentController.add(try XCTUnwrap(rules))
        let page = try RSSPoCWebPage(configuration: configuration)
        defer { page.close() }
        let navigation = FixtureNavigationPolicyProbe(allowedPaths: ["/page", "/frame", "/nested-frame"])
        page.view.navigationDelegate = navigation
        let pageLoaded = expectation(description: "主页面完成")
        navigation.onMainPageFinished = { pageLoaded.fulfill() }
        navigation.onMainPageFailure = { pageLoaded.fulfill() }
        XCTAssertNotNil(page.view.load(URLRequest(url: pageURL)))
        let mainLoadResult = await XCTWaiter.fulfillment(of: [pageLoaded], timeout: 10)
        XCTAssertEqual(mainLoadResult, .completed)
        XCTAssertFalse(navigation.mainPageFailed)

        let result = try await page.view.callAsyncJavaScript("""
            return await Promise.race([
                window.boundaryResult,
                new Promise(resolve => setTimeout(() => resolve({fixtureTimeout:true}), 5000))
            ]);
            """, arguments: [:], in: nil, contentWorld: .page) as? [String: Any]
        XCTAssertNil(result?["fixtureTimeout"], "本地WebKit白名单fixture未在固定时限内完成探针")
        XCTAssertEqual(result?["imageWidth"] as? Int, 0, "未批准的iframe图片应由声明式规则静态阻断")
        XCTAssertEqual(result?["approved"] as? [Int], [200, 200])
        XCTAssertEqual(result?["unknownFetchBlocked"] as? Bool, true)
        XCTAssertEqual(result?["redirectBlocked"] as? Bool, true, "跳转后的未批准目标不得抵达fixture服务")
        XCTAssertEqual(navigation.actions.map(\.path).sorted(), ["/frame", "/nested-frame", "/page"])
        XCTAssertTrue(navigation.actions.contains { $0.path == "/frame" && !$0.isMainFrame },
                      "导航delegate可以识别iframe文档导航")
        XCTAssertTrue(navigation.actions.contains { $0.path == "/nested-frame" && !$0.isMainFrame },
                      "导航delegate也可以识别本地嵌套frame文档导航")

        let requests = server.requests
        XCTAssertEqual(requests.filter { $0.path == "/page" }.count, 1)
        XCTAssertEqual(requests.filter { $0.path == "/frame" }.count, 1)
        XCTAssertEqual(requests.filter { $0.path == "/nested-frame" }.count, 1)
        XCTAssertEqual(requests.filter { $0.path == "/pixel" && $0.query == "approved=1" }.count, 2,
                       "相同的精确白名单URL可以被子frame重复请求；ContentRuleList没有运行时计数预算")
        XCTAssertEqual(requests.filter { $0.path == "/redirect-pixel" }.count, 1)
        XCTAssertFalse(requests.contains { ["/unreviewed-image", "/unreviewed-nested-image", "/unreviewed-fetch", "/denied-redirect-target"].contains($0.path) })
        XCTAssertEqual(requests.count, 6, "delegate只看文档导航；本地服务收到六次HTTP请求")
        print("S8_WEBKIT_BOUNDARY fixture=loopback documentNavigationCallbacks=3 allowedDocuments=3 nestedFrames=1 repeatedApprovedSubresourceHTTP=2 blockedUnknownSubresourceHTTP=0 redirectDestinationHTTP=0 actualHTTP=\(requests.count) requestBudget=notProvidedByNavigationDelegateOrContentRuleList")
        try await contentStore.removeContentRuleList(forIdentifier: ruleIdentifier)
    }

    func testNavigationDelegateRejectsUnapprovedCrossOriginIframeBeforeRequest() async throws {
        let server = try VideoStillFixtureServer(directory: fixtures, routes: [
            "/page": .init(body: Data("<iframe id='child' src='/frame'></iframe>".utf8)),
            "/frame": .init(body: Data("<p>fixture</p>".utf8)),
            "/denied-frame": .init(body: Data("<p>must-not-load</p>".utf8))
        ])
        let base = try await server.start()
        defer { server.stop() }
        let page = try RSSPoCWebPage(configuration: configuration())
        defer { page.close() }
        let navigation = FixtureNavigationPolicyProbe(allowedPaths: ["/page", "/frame"])
        page.view.navigationDelegate = navigation
        let pageLoaded = expectation(description: "主页面完成")
        let rejectedFrame = expectation(description: "未批准iframe导航在HTTP前拒绝")
        navigation.onMainPageFinished = { pageLoaded.fulfill() }
        navigation.onMainPageFailure = { pageLoaded.fulfill() }
        navigation.onRejected = { path, isMainFrame in
            if path == "/denied-frame" && !isMainFrame { rejectedFrame.fulfill() }
        }
        XCTAssertNotNil(page.view.load(URLRequest(url: base.appendingPathComponent("page"))))
        let mainLoadResult = await XCTWaiter.fulfillment(of: [pageLoaded], timeout: 10)
        XCTAssertEqual(mainLoadResult, .completed)
        XCTAssertFalse(navigation.mainPageFailed)
        let deniedURL = try crossOriginLocalURL(base.appendingPathComponent("denied-frame"))
        _ = try await page.view.callAsyncJavaScript("""
            document.getElementById('child').src = target;
            return true;
            """, arguments: ["target": deniedURL.absoluteString], in: nil, contentWorld: .page)
        let rejectedFrameResult = await XCTWaiter.fulfillment(of: [rejectedFrame], timeout: 5)
        XCTAssertEqual(rejectedFrameResult, .completed)
        XCTAssertTrue(navigation.actions.contains { $0.path == "/denied-frame" && !$0.isMainFrame })
        XCTAssertFalse(server.requests.contains { $0.path == "/denied-frame" },
                       "被导航delegate拒绝的跨源frame文档在本地HTTP服务没有产生请求")
        print("S8_WEBKIT_BOUNDARY fixture=loopback rejectedIframeNavigation=true rejectedFrameHTTP=0 requestsBeforeCancellation=policy-cancel")
    }

    func testEncryptedHLSRequestsKeyAndSegmentsWithScopedCookie() async throws {
        try await playWebMedia("secure/encrypted.m3u8", inFrame: false, encrypted: true)
    }

    private func crossOriginLocalURL(_ url: URL) throws -> URL {
        var parts = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        parts.host = "localhost"
        return try XCTUnwrap(parts.url)
    }

    private func denyLocalFixtureResourcesExcept(_ allowed: [URL], port: Int) throws -> String {
        func rule(_ filter: String, _ action: String) -> [String: Any] {
            ["trigger": ["url-filter": filter], "action": ["type": action]]
        }
        var rules = [
            rule("127\\.0\\.0\\.1:\(port)/", "block"),
            rule("localhost:\(port)/", "block")
        ]
        for url in allowed {
            guard ["127.0.0.1", "localhost"].contains(url.host ?? ""),
                  url.path.range(of: #"^/[A-Za-z0-9/-]+$"#, options: .regularExpression) != nil else {
                throw URLError(.badURL)
            }
            let host = url.host == "127.0.0.1" ? "127\\.0\\.0\\.1" : "localhost"
            let query = url.query.map { "\\?" + NSRegularExpression.escapedPattern(for: $0) } ?? ""
            rules.append(rule("\(host):\(port)\(url.path)\(query)$", "ignore-previous-rules"))
        }
        return String(decoding: try JSONSerialization.data(withJSONObject: rules, options: [.sortedKeys]), as: UTF8.self)
    }

    private func playWebMedia(_ media: String, inFrame: Bool, encrypted: Bool = false) async throws {
        let video = "<video id='video' muted playsinline></video>"
        var routes: [String: VideoStillFixtureServer.Response] = [
            "/page": .init(body: Data((inFrame ? "<iframe id='child' src='/frame'></iframe>" : video).utf8)),
            "/frame": .init(body: Data(video.utf8)),
            "/media-url": .init(body: try JSONSerialization.data(withJSONObject: ["url": "/" + media]), type: "application/json")
        ]
        if encrypted {
            let directory = fixtures
            let mediaRoutes = try await Task.detached { try RSSMediaFixture.encryptedHLS(directory: directory) }.value
            for (path, response) in mediaRoutes { routes[path] = response }
        }
        let server = try VideoStillFixtureServer(directory: fixtures, routes: routes)
        let base = try await server.start()
        defer { server.stop() }
        let config = configuration()
        if encrypted {
            let cookie = try XCTUnwrap(HTTPCookie(properties: [.domain: "127.0.0.1", .path: "/secure/", .name: "fixture_session", .value: "synthetic"]))
            await config.websiteDataStore.httpCookieStore.setCookie(cookie)
        }
        let page = try RSSPoCWebPage(configuration: config)
        defer { page.close() }
        try await page.waiter.load { page.view.load(URLRequest(url: base.appendingPathComponent("page"))) }
        let outcome = try await page.view.callAsyncJavaScript("""
            const target = inFrame ? document.getElementById('child').contentDocument : document;
            const video = target.getElementById('video');
            const config = await (await fetch('/media-url')).json();
            video.src = config.url;
            video.muted = true;
            return await new Promise((resolve, reject) => {
                const cleanup = () => { clearTimeout(deadline); video.removeEventListener('timeupdate', advanced); video.removeEventListener('error', failed); video.pause(); };
                const advanced = () => { if (video.currentTime > 0.2 && video.videoWidth > 0) { const value = {time:video.currentTime,width:video.videoWidth}; cleanup(); resolve(value); } };
                const failed = () => { cleanup(); reject(new Error('media-error')); };
                const deadline = setTimeout(() => { cleanup(); reject(new Error('media-timeout')); }, 8000);
                video.addEventListener('timeupdate', advanced);
                video.addEventListener('error', failed);
                video.play().catch(failed);
                advanced();
            });
            """, arguments: ["inFrame": inFrame], in: nil, contentWorld: .page) as? [String: Any]
        XCTAssertGreaterThan(try XCTUnwrap(outcome?["time"] as? Double), 0.2)
        XCTAssertEqual(outcome?["width"] as? Int, 320)
        XCTAssertTrue(server.requests.contains { $0.path == "/media-url" })
        XCTAssertTrue(server.requests.contains { $0.path == "/" + media })
        if media.hasSuffix("m3u8") { XCTAssertTrue(server.requests.contains { $0.path.hasSuffix(".m4s") }) }
        if encrypted {
            for path in ["/secure/encrypted.m3u8", "/secure/init.mp4", "/secure/0.m4s", "/secure/key"] {
                let request = try XCTUnwrap(server.requests.first { $0.path == path })
                XCTAssertEqual(request.headers["cookie"], "fixture_session=synthetic")
            }
            XCTAssertTrue(server.requests.filter { !$0.path.hasPrefix("/secure/") }.allSatisfy { $0.headers["cookie"] == nil })
        }
    }

    private func configuration() -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.allowsInlineMediaPlayback = true
        // 仅测试固定、静音媒体的播放管道；生产页面仍按用户交互/源配置另行设计。
        configuration.mediaTypesRequiringUserActionForPlayback = []
        return configuration
    }

    private func pixel() -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1 // 固定为1个物理像素，不随模拟器的2x/3x屏幕倍率改变。
        return UIGraphicsImageRenderer(size: CGSize(width: 1, height: 1), format: format).pngData { context in
            UIColor.blue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        }
    }
}

@MainActor
private final class FixtureNavigationPolicyProbe: NSObject, WKNavigationDelegate {
    struct Action {
        var path: String
        var isMainFrame: Bool
    }

    private let allowedPaths: Set<String>
    private(set) var actions: [Action] = []
    private(set) var mainPageFailed = false
    var onMainPageFinished: (() -> Void)?
    var onMainPageFailure: (() -> Void)?
    var onRejected: ((String, Bool) -> Void)?

    init(allowedPaths: Set<String>) { self.allowedPaths = allowedPaths }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        let path = navigationAction.request.url?.path ?? ""
        let isMainFrame = navigationAction.targetFrame?.isMainFrame ?? true
        actions.append(Action(path: path, isMainFrame: isMainFrame))
        guard allowedPaths.contains(path) else {
            decisionHandler(.cancel)
            onRejected?(path, isMainFrame)
            return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if webView.url?.path == "/page" { onMainPageFinished?() }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        failMainPageIfNeeded(webView)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        failMainPageIfNeeded(webView)
    }

    private func failMainPageIfNeeded(_ webView: WKWebView) {
        guard webView.url?.path == "/page" else { return }
        mainPageFailed = true
        onMainPageFailure?()
    }
}
