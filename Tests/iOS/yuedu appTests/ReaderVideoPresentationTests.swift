import SwiftUI
import WebKit
import XCTest
@testable import yuedu_app

/// 全屏播放器暂时覆盖真正的 ReaderView，不能被当作关闭阅读器而销毁自动播放的源网页。
/// 销毁后返回会创建第二个网页、重新执行 autoplay，表现为刚退出播放器又弹出。
@MainActor
final class ReaderVideoPresentationTests: XCTestCase {
    func testFullscreenDismissalDoesNotRecreateAutoplayPage() async throws {
        let directory = URL.temporaryDirectory.appendingPathComponent("ReaderVideoPresentationTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = BookStore(metadataFileURL: directory.appendingPathComponent("books_meta.json"))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousWindow = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        let dismantled = expectation(description: "阅读器内容真正移除")
        let reader = UIHostingController(rootView: AnyView(ReaderView(bookId: UUID()).environmentObject(store)
            .background(ReaderTeardownProbe { dismantled.fulfill() })))
        let container = UIViewController()
        container.addChild(reader)
        container.view.addSubview(reader.view)
        reader.didMove(toParent: container)
        window.rootViewController = container
        window.makeKeyAndVisible()
        reader.view.frame = container.view.bounds
        reader.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previousWindow?.makeKeyAndVisible()
            ReaderWebEmbedManager.shared.stopAll()
            store.waitForQueuedWrites()
        }
        reader.view.layoutIfNeeded()

        // 本机固定 MP4 验证实际播放，网页的实例标记用于检查是否重复执行 autoplay。
        let server = try VideoStillFixtureServer(directory: VideoStillFixtures.directory())
        let base = try await server.start()
        defer { server.stop() }
        let played = expectation(description: "源视频播放时钟推进")
        let html = """
        <html><body><video autoplay muted playsinline controls src="\(base.appendingPathComponent("video-still-landscape.mp4").absoluteString)"
        ontimeupdate="if(this.currentTime>0.05)window.webkit.messageHandlers.playback.postMessage(this.currentTime)"></video>
        <script>window.pageInstance='original';</script></body></html>
        """
        let embed = ReaderWebEmbed(src: "data:text/html;base64," + Data(html.utf8).base64EncodedString(),
                                   title: "Synthetic video", referer: nil)
        let original = ReaderWebEmbedManager.shared.webView(for: embed)
        original.frame = CGRect(x: 0, y: 0, width: 300, height: 200)
        container.view.addSubview(original)
        let loaded = expectation(description: "源播放器页面完成加载")
        let navigation = PageLoaded(loaded, played: played)
        original.navigationDelegate = navigation
        original.configuration.userContentController.add(navigation, name: "playback")
        defer { original.configuration.userContentController.removeScriptMessageHandler(forName: "playback") }
        await fulfillment(of: [loaded, played], timeout: 10)
        XCTAssertTrue(server.requests.contains { $0.path == "/video-still-landscape.mp4" })
        let instance = try await original.evaluateJavaScript("window.pageInstance") as? String
        XCTAssertEqual(instance, "original")

        let player = UIViewController()
        player.modalPresentationStyle = .fullScreen
        let presented = expectation(description: "全屏播放器覆盖阅读器")
        container.present(player, animated: false) { presented.fulfill() }
        await fulfillment(of: [presented], timeout: 10)
        XCTAssertTrue(ReaderWebEmbedManager.shared.isActive(embed), "暂时覆盖不应销毁源播放器页面")

        let dismissed = expectation(description: "退出全屏播放器回到阅读器")
        player.dismiss(animated: false) { dismissed.fulfill() }
        await fulfillment(of: [dismissed], timeout: 10)
        let returned = ReaderWebEmbedManager.shared.webView(for: embed)
        XCTAssertTrue(returned === original, "返回必须复用同一网页，不能再次加载 autoplay")
        let returnedInstance = try await returned.evaluateJavaScript("window.pageInstance") as? String
        XCTAssertEqual(returnedInstance, "original")

        // 真正退出仍释放资源，不能用永久保留网页来掩盖重复弹出。
        // 替换内容会拆除 SwiftUI 层级；仅换 window.rootViewController 而仍持有 host 不会拆除它。
        reader.rootView = AnyView(Color.clear)
        reader.view.layoutIfNeeded()
        await fulfillment(of: [dismantled], timeout: 10)
        XCTAssertFalse(ReaderWebEmbedManager.shared.isActive(embed), "真正退出阅读器后仍必须释放网页")
    }

    private final class PageLoaded: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        let loaded: XCTestExpectation
        let played: XCTestExpectation
        private var reportedPlayback = false
        init(_ loaded: XCTestExpectation, played: XCTestExpectation) { self.loaded = loaded; self.played = played }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { loaded.fulfill() }
        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard !reportedPlayback, let time = message.body as? Double, time > 0.05 else { return }
            reportedPlayback = true
            played.fulfill()
        }
    }
}
