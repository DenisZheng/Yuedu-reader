import UIKit
import WebKit
import XCTest
@testable import yuedu_app

/// S1平台约束实验。页面/脚本全部自行构造，只访问本机固定路由，不使用真实源或账号。
@MainActor
final class RSSWebResourcePoCTests: XCTestCase {
    private let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("Fixtures/VideoStill", isDirectory: true)

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
    func testEncryptedHLSRequestsKeyAndSegmentsWithScopedCookie() async throws {
        try await playWebMedia("secure/encrypted.m3u8", inFrame: false, encrypted: true)
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
