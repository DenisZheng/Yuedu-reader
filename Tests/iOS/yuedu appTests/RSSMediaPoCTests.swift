import AVFoundation
import Foundation
import WebKit
import UIKit
import XCTest
@testable import yuedu_app

/// 仅记录诊断时间线；跨KVO/测试执行器的条目由同一锁保护，不参与播放器决策。
final class AudioTestTimeline: @unchecked Sendable {
    private let lock = NSLock()
    private let started = ProcessInfo.processInfo.systemUptime
    private var entries: [String] = []

    func record(_ event: String) {
        let entry = String(format: "+%.3f %@", ProcessInfo.processInfo.systemUptime - started, event)
        lock.lock()
        entries.append(entry)
        lock.unlock()
        // 若同步会话激活卡住，附件来不及生成；有限事件日志保留最后到达的边界。
        print("[RSS-Audio-PoC] \(entry)")
    }

    var snapshot: String {
        lock.lock()
        defer { lock.unlock() }
        return entries.joined(separator: "\n")
    }
}

/// S1约束实验，不代表RSS已接入这些能力。服务器验收到达的请求，播放器验收实际时钟推进。
@MainActor
final class RSSMediaPoCTests: XCTestCase {
    private let fixtures = VideoStillFixtures.directory()

    func testHTTPRangeHEADAndAuthenticationFixture() async throws {
        let server = try VideoStillFixtureServer(directory: fixtures, referer: "https://fixture.invalid/page")
        let base = try await server.start()
        defer { server.stop() }
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: base.appendingPathComponent("video-still-landscape.mp4"))
        let (_, denied) = try await session.data(for: request)
        XCTAssertEqual((denied as? HTTPURLResponse)?.statusCode, 403)
        request.setValue("https://fixture.invalid/page", forHTTPHeaderField: "Referer")
        request.httpMethod = "HEAD"
        let (head, response) = try await session.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertTrue(head.isEmpty)
        let count = try XCTUnwrap(Int((response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Length") ?? ""))
        XCTAssertGreaterThan(count, 1024)
        request.httpMethod = "GET"
        for (range, length, status) in [("bytes=0-1", 2, 206), ("bytes=-8", 8, 206), ("bytes=\(count - 8)-", 8, 206), ("bytes=\(count)-", 0, 416)] {
            request.setValue(range, forHTTPHeaderField: "Range")
            let (data, response) = try await session.data(for: request)
            XCTAssertEqual(data.count, length)
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, status)
            XCTAssertNotNil((response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Range"))
        }
    }

    func testMP4ActuallySeeksAndAdvances() async throws {
        try await play("video-still-landscape.mp4")
    }

    func testHLSActuallyLoadsSegmentsSeeksAndAdvances() async throws {
        let requests = try await play("video-still-hls.m3u8")
        XCTAssertTrue(requests.contains { $0.path.hasSuffix(".m4s") })
        XCTAssertTrue(requests.contains { $0.path.hasSuffix("-init.mp4") })
    }

    func testAudioActuallySeeksAndAdvances() async throws {
        // 独立宿主没有普通App的音频会话；显式建立播放条件，并在队列外等待成功。
        let timeline = AudioTestTimeline()
        timeline.record("HTTP test started isolatedHost=\(RSSPoCTestHost.isEnabled) appState=\(UIApplication.shared.applicationState.rawValue)")
        defer {
            let attachment = XCTAttachment(string: timeline.snapshot)
            attachment.name = "http-audio-timeline"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        let previous = try await Task.detached {
            let session = AVAudioSession.sharedInstance()
            let previous = (session.category, session.mode, session.categoryOptions)
            timeline.record("setCategory begin")
            try session.setCategory(.playback)
            timeline.record("setActive begin")
            try session.setActive(true)
            timeline.record("setActive returned")
            return previous
        }.value
        let result: Result<Void, Error>
        do {
            try await play("video-still-audio-only.m4a", timeline: timeline)
            result = .success(())
        } catch { result = .failure(error) }
        do {
            timeline.record("restore session begin")
            try await Task.detached {
                let session = AVAudioSession.sharedInstance()
                try session.setActive(false)
                try session.setCategory(previous.0, mode: previous.1, options: previous.2)
            }.value
            timeline.record("restore session returned")
        } catch { XCTFail("测试音频会话恢复失败：\(error)") }
        try result.get()
    }

    /// 最小平台回归：不经过RSS、认证头或网络，仍须由真实音频输出推进播放时钟。
    func testLocalAudioActuallyAdvances() async throws {
        let timeline = AudioTestTimeline()
        timeline.record("test started isolatedHost=\(RSSPoCTestHost.isEnabled) appState=\(UIApplication.shared.applicationState.rawValue)")
        let previous = try await Task.detached {
            let session = AVAudioSession.sharedInstance()
            let value = (session.category, session.mode, session.categoryOptions)
            timeline.record("setCategory begin")
            try session.setCategory(.playback)
            timeline.record("setActive begin")
            try session.setActive(true)
            timeline.record("setActive returned category=\(session.category.rawValue) mode=\(session.mode.rawValue) sampleRate=\(session.sampleRate) outputs=\(session.currentRoute.outputs.map(\.portType.rawValue))")
            return value
        }.value
        let asset = AVURLAsset(url: fixtures.appendingPathComponent("video-still-audio-only.m4a"))
        let item = AVPlayerItem(asset: asset)
        let player = AVPlayer(playerItem: item)
        timeline.record("asset/item/player created status=\(item.status.rawValue)")
        var playbackState: String?
        defer {
            let attachment = XCTAttachment(string: "\(timeline.snapshot)\nBEFORE TEARDOWN \(playbackState ?? Self.audioState(player: player, item: item))")
            attachment.name = "local-audio-timeline"
            attachment.lifetime = .keepAlways
            add(attachment)
            player.pause()
            player.replaceCurrentItem(with: nil)
        }
        let ready = expectation(description: "本地音频ready")
        let observation = item.observe(\.status, options: [.initial, .new]) { value, _ in
            timeline.record("status KVO=\(value.status.rawValue) error=\(String(describing: value.error))")
            if value.status != .unknown { ready.fulfill() }
        }
        defer { observation.invalidate() }
        await fulfillment(of: [ready], timeout: 10)
        timeline.record("ready wait returned status=\(item.status.rawValue) error=\(String(describing: item.error))")
        XCTAssertEqual(item.status, .readyToPlay)
        let advanced = expectation(description: "本地音频时钟越过0.2秒")
        let token = player.addBoundaryTimeObserver(forTimes: [NSValue(time: CMTime(seconds: 0.2, preferredTimescale: 600))], queue: .main) {
            timeline.record("0.2 boundary callback time=\(player.currentTime().seconds)")
            advanced.fulfill()
        }
        defer { player.removeTimeObserver(token) }
        timeline.record("play() called")
        player.play()
        await fulfillment(of: [advanced], timeout: 8)
        timeline.record("clock wait returned time=\(player.currentTime().seconds) rate=\(player.rate) control=\(player.timeControlStatus.rawValue)")
        XCTAssertGreaterThan(player.currentTime().seconds, 0.2)
        let stateBeforeTeardown = Self.audioState(player: player, item: item)
        playbackState = stateBeforeTeardown
        let attachment = XCTAttachment(string: stateBeforeTeardown)
        attachment.name = "local-audio-platform-state"
        attachment.lifetime = .keepAlways
        add(attachment)
        timeline.record("pause and detach player begin")
        player.pause()
        player.replaceCurrentItem(with: nil)
        timeline.record("pause and detach player returned")
        timeline.record("restore session begin")
        try await Task.detached {
            let session = AVAudioSession.sharedInstance()
            try session.setActive(false)
            try session.setCategory(previous.0, mode: previous.1, options: previous.2)
        }.value
        timeline.record("restore session returned")
    }

    static func audioState(player: AVPlayer, item: AVPlayerItem) -> String {
        let session = AVAudioSession.sharedInstance()
        let suppressed: String
        if #available(iOS 26.0, *) { suppressed = String(player.audioOutputSuppressedDueToNonMixableAudioRoute) }
        else { suppressed = "unavailable" }
        // 只读诊断，不设置sourceClock、优先路由、静音或音量来制造时钟推进。
        let output = "playerStatus=\(player.status.rawValue) outputSuppressed=\(suppressed) muted=\(player.isMuted) volume=\(player.volume) sourceClockOverridden=\(player.sourceClock != nil) effectiveTimebaseRate=\(item.timebase.map(CMTimebaseGetEffectiveRate) ?? -1)"
        return "\(output)\nstatus=\(item.status.rawValue) error=\(String(describing: item.error)) time=\(player.currentTime().seconds) rate=\(player.rate) control=\(player.timeControlStatus.rawValue) waiting=\(player.reasonForWaitingToPlay?.rawValue ?? "none") bufferEmpty=\(item.isPlaybackBufferEmpty) likely=\(item.isPlaybackLikelyToKeepUp) duration=\(item.duration.seconds) timebaseRate=\(item.timebase.map(CMTimebaseGetRate) ?? -1)\ncategory=\(session.category.rawValue) mode=\(session.mode.rawValue) sampleRate=\(session.sampleRate) outputs=\(session.currentRoute.outputs.map(\.portType.rawValue))"
    }

    @discardableResult
    private func play(_ name: String, timeline: AudioTestTimeline? = nil) async throws -> [VideoStillFixtureServer.Request] {
        let referer = "https://fixture.invalid/player"
        let server = try VideoStillFixtureServer(directory: fixtures, referer: referer)
        timeline?.record("fixture server start begin")
        let base = try await server.start()
        timeline?.record("fixture server ready")
        defer { server.stop() }
        let asset = HeaderedMediaAsset.make(url: base.appendingPathComponent(name), headers: ["Referer": referer])
        let item = AVPlayerItem(asset: asset)
        let player = AVPlayer(playerItem: item)
        timeline?.record("HTTP asset/item/player created status=\(item.status.rawValue)")
        // 当前模拟器无显示consumer时HLS seek不完成；PoC使用真实显示层，而非只查ready状态。
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        let controller = UIViewController()
        window.rootViewController = controller
        let layer = AVPlayerLayer(player: player)
        layer.frame = CGRect(x: 0, y: 0, width: 320, height: 180)
        controller.view.layer.addSublayer(layer)
        window.isHidden = false
        defer { layer.player = nil; window.isHidden = true }
        let ready = expectation(description: "AVPlayer完成实际资源加载")
        let observation = item.observe(\.status, options: [.initial, .new]) { item, _ in
            timeline?.record("status KVO=\(item.status.rawValue) error=\(String(describing: item.error))")
            if item.status != .unknown { ready.fulfill() }
        }
        defer {
            let trace = XCTAttachment(string: Self.audioState(player: player, item: item) + "\n" + server.requests.map(\.description).joined(separator: "\n"))
            trace.name = "\(name)-transport"
            trace.lifetime = .keepAlways
            add(trace)
            timeline?.record("HTTP state before teardown \(Self.audioState(player: player, item: item))")
            observation.invalidate()
            player.pause()
            player.replaceCurrentItem(with: nil)
            timeline?.record("HTTP pause and detach returned")
        }
        await fulfillment(of: [ready], timeout: 10)
        timeline?.record("ready wait returned status=\(item.status.rawValue)")
        guard item.status == .readyToPlay else {
            XCTFail("媒体加载失败：\(String(describing: item.error))")
            return server.requests
        }
        let sought = expectation(description: "seek完成回调")
        timeline?.record("seek(2) called")
        player.seek(to: CMTime(seconds: 2, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { completed in
            timeline?.record("seek completed=\(completed)")
            XCTAssertTrue(completed)
            sought.fulfill()
        }
        await fulfillment(of: [sought], timeout: 5)
        let requests = XCTAttachment(string: server.requests.map(\.description).joined(separator: "\n"))
        requests.name = "\(name)-seek-requests"
        requests.lifetime = .keepAlways
        add(requests)
        let advanced = expectation(description: "seek后播放时钟越过2.2秒")
        let observer = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.1, preferredTimescale: 600), queue: .main) { time in
            if time.seconds > 2.2 { advanced.fulfill() }
        }
        defer { player.removeTimeObserver(observer) }
        timeline?.record("play() called")
        player.play()
        await fulfillment(of: [advanced], timeout: 8)
        timeline?.record("clock wait returned time=\(player.currentTime().seconds)")
        XCTAssertGreaterThan(player.currentTime().seconds, 2.2)
        XCTAssertFalse(server.requests.isEmpty)
        XCTAssertTrue(server.requests.allSatisfy { $0.referer == referer })
        return server.requests
    }

    /// S1记录现有asset选项的安全边界，不是“允许跨站认证”的产品合同。
    func testExistingHeaderOptionCrossHostRedirectBoundary() async throws {
        let target = try VideoStillFixtureServer(directory: fixtures)
        let targetBase = try await target.start()
        defer { target.stop() }
        var remote = try XCTUnwrap(URLComponents(url: targetBase.appendingPathComponent("video-still-landscape.mp4"), resolvingAgainstBaseURL: false))
        remote.host = "localhost"
        let redirectedURL = try XCTUnwrap(remote.url)
        let origin = try VideoStillFixtureServer(directory: fixtures, routes: [
            "/redirect": .init(body: Data(), status: "302 Found", headers: ["Location": redirectedURL.absoluteString])
        ])
        let base = try await origin.start()
        defer { origin.stop() }
        let frame = try await VideoStillExtractor.still(
            of: VideoStream(url: base.appendingPathComponent("redirect"), headers: ["X-Fixture-Auth": "synthetic"]),
            fitting: CGSize(width: 320, height: 180)
        )
        XCTAssertFalse(frame.jpeg.isEmpty)
        let requests = target.requests
        XCTAssertFalse(requests.isEmpty)
        // 当前未公开选项按asset应用，重定向后也可能携带源私有头；S6不可照搬。
        XCTAssertTrue(requests.contains { $0.headers["x-fixture-auth"] == "synthetic" })
    }

    func testWebKitMainDocumentHeaderDoesNotAuthenticateSubresources() async throws {
        let pixel = try XCTUnwrap(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aXhQAAAAASUVORK5CYII="))
        let server = try VideoStillFixtureServer(directory: fixtures, routes: [
            "/page": .init(body: Data("<html><body><img id='probe' src='/image'></body></html>".utf8), requiredHeaders: ["x-fixture-auth": "synthetic"]),
            "/image": .init(body: pixel, type: "image/png", requiredHeaders: ["x-fixture-auth": "synthetic"])
        ])
        let base = try await server.start()
        defer { server.stop() }
        let (view, waiter) = webView()
        var request = URLRequest(url: base.appendingPathComponent("page"))
        request.setValue("synthetic", forHTTPHeaderField: "X-Fixture-Auth")
        try await waiter.load { view.load(request) }
        let width = try await view.evaluateJavaScript("document.getElementById('probe').naturalWidth") as? Int
        XCTAssertEqual(width, 0)
        XCTAssertEqual(server.requests.first { $0.path == "/page" }?.headers["x-fixture-auth"], "synthetic")
        let image = try XCTUnwrap(server.requests.first { $0.path == "/image" })
        XCTAssertNil(image.headers["x-fixture-auth"], "首个URLRequest的头部不会自动传给WKWebView的图片请求")
        XCTAssertTrue(WKWebView.handlesURLScheme("https"))
        XCTAssertFalse(WKWebView.handlesURLScheme("readerfork-fixture"))
    }

    func testWebKitCrossOriginFetchEnforcesCORSWithoutLeakingMainHeaders() async throws {
        let remote = try VideoStillFixtureServer(directory: fixtures, routes: [
            "/blocked": .init(body: Data("blocked".utf8)),
            "/allowed": .init(body: Data("allowed".utf8), headers: ["Access-Control-Allow-Origin": "*"])
        ])
        let remoteURL = try await remote.start()
        defer { remote.stop() }
        let server = try VideoStillFixtureServer(directory: fixtures, routes: [
            "/page": .init(body: Data("<html><body>CORS fixture</body></html>".utf8))
        ])
        let base = try await server.start()
        defer { server.stop() }
        let (view, waiter) = webView()
        var request = URLRequest(url: base.appendingPathComponent("page"))
        request.setValue("synthetic", forHTTPHeaderField: "X-Fixture-Auth")
        try await waiter.load { view.load(request) }
        let result = try await view.callAsyncJavaScript("""
            let denied = false;
            try { await fetch(base + 'blocked'); } catch (error) { denied = error instanceof TypeError; }
            const body = await (await fetch(base + 'allowed')).text();
            return denied && body === 'allowed';
            """, arguments: ["base": remoteURL.absoluteString], in: nil, contentWorld: .page) as? Bool
        XCTAssertEqual(result, true)
        XCTAssertEqual(Set(remote.requests.map(\.path)), ["/blocked", "/allowed"])
        XCTAssertTrue(remote.requests.allSatisfy { $0.headers["x-fixture-auth"] == nil })
    }

    private func webView() -> (WKWebView, RSSPoCNavigationWaiter) {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 320, height: 240), configuration: configuration)
        let waiter = RSSPoCNavigationWaiter()
        view.navigationDelegate = waiter
        return (view, waiter)
    }
}
