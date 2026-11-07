import WebKit
import XCTest

/// custom-scheme仅为平台PoC，不是RSS生产代理或许可扩大。
@MainActor
final class RSSSchemeResourcePoCTests: XCTestCase {
    private let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("Fixtures/VideoStill", isDirectory: true)
    private let origin = URL(string: "readerfork-fixture://fixture/")!

    func testCustomSchemeLoadsHTMLImagesAndRejectsUnlistedResources() async throws {
        let handler = RSSPoCSchemeHandler(resources: [
            "/page": html("<img id='good' src='pixel.svg'><img id='bad' src='not-allowed'>"),
            "/pixel.svg": svg()
        ])
        let page = try RSSPoCWebPage(configuration: configuration(handler))
        defer { page.close() }
        try await page.waiter.load { page.view.load(URLRequest(url: origin.appendingPathComponent("page"))) }
        let result = try await page.view.evaluateJavaScript("({good:document.getElementById('good').naturalWidth,bad:document.getElementById('bad').naturalWidth})") as? [String: Int]
        XCTAssertEqual(result?["good"], 1)
        XCTAssertEqual(result?["bad"], 0)
        XCTAssertTrue(handler.startedPaths.contains("/not-allowed"))
    }

    func testStopLoadingCancelsHeldResourceAndSuppressesLateDelivery() async throws {
        let handler = RSSPoCSchemeHandler(resources: ["/page": html("<img src='/held.svg'>"), "/held.svg": svg()], heldPaths: ["/held.svg"])
        let page = try RSSPoCWebPage(configuration: configuration(handler))
        defer { page.close() }
        page.view.navigationDelegate = nil
        let held = expectation(description: "WebKit实际开始子资源请求")
        let stopped = expectation(description: "WebKit实际通知停止子资源请求")
        handler.onHeld = { held.fulfill() }
        handler.onStopped = { stopped.fulfill() }
        page.view.load(URLRequest(url: origin.appendingPathComponent("page")))
        await fulfillment(of: [held], timeout: 5)
        XCTAssertEqual(handler.pendingCount, 1)
        page.view.stopLoading()
        await fulfillment(of: [stopped], timeout: 5)
        XCTAssertEqual(handler.stoppedPaths, ["/held.svg"])
        XCTAssertEqual(handler.pendingCount, 0)
        XCTAssertEqual(handler.releaseHeld(), 0)
    }

    func testCustomSchemeMP4ActuallyPlays() async throws { try await probeMedia("video-still-landscape.mp4") }
    func testCustomSchemeHLSActuallyPlays() async throws { try await probeMedia("video-still-hls.m3u8") }

    private func probeMedia(_ name: String) async throws {
        var resources: [String: RSSPoCSchemeHandler.Resource] = ["/page": html("<video id='video' muted playsinline></video>")]
        for file in ["video-still-landscape.mp4", "video-still-hls.m3u8", "video-still-hls-init.mp4", "video-still-hls-0.m4s", "video-still-hls-1.m4s", "video-still-hls-2.m4s"] {
            let mime = file.hasSuffix("m3u8") ? "application/vnd.apple.mpegurl" : file.hasSuffix("m4s") ? "video/iso.segment" : "video/mp4"
            resources["/" + file] = .init(data: try Data(contentsOf: fixtures.appendingPathComponent(file)), mime: mime)
        }
        let handler = RSSPoCSchemeHandler(resources: resources)
        let page = try RSSPoCWebPage(configuration: configuration(handler))
        defer { page.close() }
        try await page.waiter.load { page.view.load(URLRequest(url: origin.appendingPathComponent("page"))) }
        let result = try await page.view.callAsyncJavaScript("""
            const video = document.getElementById('video');
            return await new Promise(resolve => {
                const done = status => { clearTimeout(deadline); video.removeEventListener('error', failed); video.removeEventListener('timeupdate', advanced); video.pause(); resolve({status,code:video.error?.code ?? 0,width:video.videoWidth,time:video.currentTime}); };
                const failed = () => done('error');
                const advanced = () => { if (video.currentTime > 0.2 && video.videoWidth > 0) done('played'); };
                const deadline = setTimeout(() => done('timeout'), 8000);
                video.addEventListener('error', failed);
                video.addEventListener('timeupdate', advanced);
                video.src = name;
                video.muted = true;
                video.play().catch(failed);
            });
            """, arguments: ["name": name], in: nil, contentWorld: .page) as? [String: Any]
        let outcome = try XCTUnwrap(result)
        XCTAssertEqual(outcome["status"] as? String, "played")
        XCTAssertEqual(outcome["code"] as? Int, 0)
        XCTAssertEqual(outcome["width"] as? Int, 320)
        XCTAssertGreaterThan(try XCTUnwrap(outcome["time"] as? Double), 0.2)
        XCTAssertTrue(handler.startedPaths.contains("/" + name))
        if name.hasSuffix("m3u8") { XCTAssertTrue(handler.startedPaths.contains { $0.hasSuffix(".m4s") }) }
        let attachment = XCTAttachment(data: try JSONSerialization.data(withJSONObject: ["outcome": outcome, "requests": handler.startedRequests], options: [.sortedKeys]), uniformTypeIdentifier: "public.json")
        attachment.name = "\(name)-custom-scheme-outcome"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func html(_ value: String) -> RSSPoCSchemeHandler.Resource { .init(data: Data(value.utf8), mime: "text/html; charset=utf-8") }
    private func svg() -> RSSPoCSchemeHandler.Resource {
        .init(data: Data("<svg xmlns='http://www.w3.org/2000/svg' width='1' height='1'><rect width='1' height='1' fill='blue'/></svg>".utf8), mime: "image/svg+xml")
    }
    private func configuration(_ handler: RSSPoCSchemeHandler) -> WKWebViewConfiguration {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        config.setURLSchemeHandler(handler, forURLScheme: "readerfork-fixture")
        return config
    }
}
