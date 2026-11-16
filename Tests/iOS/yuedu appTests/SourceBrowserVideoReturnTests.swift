import Combine
import SwiftUI
import WebKit
import XCTest
@testable import yuedu_app

/// 书源浏览器的真实WebKit媒体与SwiftUI拆除链路；不是ReaderView被普通UIViewController覆盖。
@MainActor
final class SourceBrowserVideoReturnTests: XCTestCase {
    func testPortraitVideoCannotRestartAfterBrowserNavigationBack() async throws {
        try await verifyReturn(mediaFile: "video-still-portrait.mp4", portrait: true)
    }

    func testLandscapeVideoCannotRestartAfterBrowserNavigationBack() async throws {
        try await verifyReturn(mediaFile: "video-still-landscape.mp4", portrait: false)
    }

    private func verifyReturn(mediaFile: String, portrait: Bool) async throws {
        let server = try VideoStillFixtureServer(directory: VideoStillFixtures.directory())
        let base = try await server.start()
        defer { server.stop() }
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let webView = ObservedMediaWebView(frame: .zero, configuration: configuration)
        let bridge = JsBridgeBrowserBridge()
        let coordinator = JsBridgeBrowserRepresentable.Coordinator()
        coordinator.bridge = bridge
        coordinator.webView = webView
        webView.navigationDelegate = coordinator
        webView.uiDelegate = coordinator.uiDelegate
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        let navigation = UINavigationController(rootViewController: UIViewController())
        let dismantled = expectation(description: "书源网页导航返回后实际拆除")
        let ready = expectation(description: "视频播放时钟推进")
        let enteredFullscreen = expectation(description: "WebKit实际进入系统视频全屏")
        let events = PlaybackEvents(played: ready, enteredFullscreen: enteredFullscreen)
        webView.configuration.userContentController.add(events, name: "browserPlayback")
        var browser: UIHostingController<AnyView>? = UIHostingController(rootView: AnyView(
            BrowserWindow(webView: webView, coordinator: coordinator, onDismantle: { dismantled.fulfill() })
        ))
        window.rootViewController = navigation
        window.makeKeyAndVisible()
        navigation.pushViewController(try XCTUnwrap(browser), animated: false)
        browser?.view.layoutIfNeeded()
        defer {
            // 即使原缺陷令旧页面重新全屏，测试也不会把它留在模拟器上。
            webView.setAllMediaPlaybackSuspended(true, completionHandler: nil)
            webView.closeAllMediaPresentations(completionHandler: nil)
            webView.stopLoading()
            webView.configuration.userContentController.removeScriptMessageHandler(forName: "browserPlayback")
            webView.navigationDelegate = nil
            webView.uiDelegate = nil
            webView.loadHTMLString("", baseURL: nil)
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        let html = """
        <html><body><video id="movie" controls muted src="\(base.appendingPathComponent(mediaFile).absoluteString)"
        ontimeupdate="if(this.currentTime>0.05)window.webkit.messageHandlers.browserPlayback.postMessage(this.currentTime)"
        onwebkitbeginfullscreen="window.webkit.messageHandlers.browserPlayback.postMessage('fullscreen')"></video></body></html>
        """
        let loaded = expectation(description: "书源视频网页完成加载")
        let phases = bridge.$phase.sink { phase in if phase == .finished { loaded.fulfill() } }
        defer { phases.cancel() }
        coordinator.loadInitial(urlString: base.absoluteString, html: html, in: webView)
        await fulfillment(of: [loaded], timeout: 10)
        _ = try await webView.callAsyncJavaScript("await document.getElementById('movie').play(); return true;", arguments: [:], in: nil, contentWorld: .page)
        await fulfillment(of: [ready], timeout: 10)
        let dimensionValue = try await webView.evaluateJavaScript("[movie.videoWidth,movie.videoHeight]") as? [Int]
        let dimensions = try XCTUnwrap(dimensionValue)
        XCTAssertEqual(dimensions.count, 2)
        XCTAssertGreaterThan(dimensions[0], 0)
        if portrait {
            XCTAssertGreaterThan(dimensions[1], dimensions[0], "竖屏回归必须播放竖向素材")
        } else {
            XCTAssertGreaterThan(dimensions[0], dimensions[1], "横屏对照必须播放横向素材")
        }
        let playing = await webView.requestMediaPlaybackState()
        XCTAssertEqual(playing, .playing)
        // iPad不会仅因play自动全屏；通过公开DOM API请求，并等待真实beginfullscreen事件。
        _ = try await webView.evaluateJavaScript("if (!movie.webkitDisplayingFullscreen) movie.webkitEnterFullscreen(); true;")
        await fulfillment(of: [enteredFullscreen], timeout: 10)
        let initialFullscreen = try await webView.evaluateJavaScript("!!movie.webkitDisplayingFullscreen") as? Bool
        XCTAssertEqual(initialFullscreen, true, "必须进入真实WebKit系统全屏，不能用普通UIViewController代替")

        // 暂时退出系统全屏不算关闭浏览器；原页面必须仍能由用户继续播放。
        await webView.closeAllMediaPresentations()
        let stillLoaded = try await webView.evaluateJavaScript("!!document.getElementById('movie')") as? Bool
        XCTAssertEqual(stillLoaded, true)
        _ = try await webView.callAsyncJavaScript("await movie.play(); return true;", arguments: [:], in: nil, contentWorld: .page)
        let resumed = await webView.requestMediaPlaybackState()
        XCTAssertEqual(resumed, .playing, "全屏暂时关闭不能永久禁止仍打开的源网页播放")

        // 导航返回会移除网页。UIKit可能在系统全屏期间仍持有host，显式移除SwiftUI内容确保调用真实dismantle。
        let closedMedia = expectation(description: "生产浏览器完成关闭系统媒体展示")
        webView.onMediaPresentationClosed = { closedMedia.fulfill() }
        _ = navigation.popViewController(animated: false)
        browser?.rootView = AnyView(Color.clear)
        browser?.view.layoutIfNeeded()
        browser = nil
        await fulfillment(of: [dismantled, closedMedia], timeout: 10)

        // 模拟已关闭页面的晚到媒体回调；仅pause并不能禁止源再次play/进入全屏。
        let retry = try await webView.evaluateJavaScript("""
        (function () {
            var video = document.getElementById('movie');
            if (!video) return 'removed';
            video.play().catch(function(){});
            try { video.webkitEnterFullscreen(); } catch (_) {}
            return 'attempted';
        })()
        """) as? String
        let afterBack = await webView.requestMediaPlaybackState()
        let fullscreen = try await webView.evaluateJavaScript("!!(document.getElementById('movie') && movie.webkitDisplayingFullscreen)") as? Bool
        print("SOURCE_BROWSER_VIDEO_RETURN portrait=\(portrait) retry=\(retry ?? "unknown") state=\(afterBack.rawValue) fullscreen=\(fullscreen ?? false)")
        XCTAssertTrue(afterBack == .none || afterBack == .suspended, "已返回的源网页必须无法恢复媒体播放")
        XCTAssertEqual(fullscreen, false, "关闭的源网页不能再次弹出系统视频全屏")
    }

    /// 只观察生产代码调用的真实关闭完成回调，测试不额外关闭媒体来让断言通过。
    private final class ObservedMediaWebView: WKWebView {
        var onMediaPresentationClosed: (() -> Void)?
        override func closeAllMediaPresentations(completionHandler: (@MainActor @Sendable () -> Void)? = nil) {
            super.closeAllMediaPresentations { [weak self] in
                let observer = self?.onMediaPresentationClosed
                self?.onMediaPresentationClosed = nil
                observer?()
                completionHandler?()
            }
        }
    }

    private final class PlaybackEvents: NSObject, WKScriptMessageHandler {
        let played: XCTestExpectation
        let enteredFullscreen: XCTestExpectation
        private var reported = false
        private var reportedFullscreen = false
        init(played: XCTestExpectation, enteredFullscreen: XCTestExpectation) {
            self.played = played; self.enteredFullscreen = enteredFullscreen
        }
        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            if (message.body as? String) == "fullscreen" {
                guard !reportedFullscreen else { return }
                reportedFullscreen = true
                enteredFullscreen.fulfill()
                return
            }
            guard !reported, let time = message.body as? Double, time > 0.05 else { return }
            reported = true
            played.fulfill()
        }
    }

    /// 创建使用非持久WebKit存储的测试窗口，拆除委托给生产representable，避免读取或同步个人Cookie。
    private struct BrowserWindow: UIViewRepresentable {
        let webView: WKWebView
        let coordinator: JsBridgeBrowserRepresentable.Coordinator
        let onDismantle: () -> Void
        func makeCoordinator() -> Box { Box(coordinator, onDismantle: onDismantle) }
        func makeUIView(context: Context) -> WKWebView { webView }
        func updateUIView(_ uiView: WKWebView, context: Context) {}
        static func dismantleUIView(_ uiView: WKWebView, coordinator: Box) {
            JsBridgeBrowserRepresentable.dismantleUIView(uiView, coordinator: coordinator.value)
            coordinator.onDismantle()
        }
        final class Box {
            let value: JsBridgeBrowserRepresentable.Coordinator
            let onDismantle: () -> Void
            init(_ value: JsBridgeBrowserRepresentable.Coordinator, onDismantle: @escaping () -> Void) {
                self.value = value; self.onDismantle = onDismantle
            }
        }
    }
}
