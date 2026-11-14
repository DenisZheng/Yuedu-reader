import AVFoundation
import Foundation
import Testing
import XCTest
@testable import yuedu_app

@Suite("RSS media forced progress capture", .serialized)
@MainActor
struct RSSMediaProgressCaptureTests {
    enum Exit: CaseIterable { case close, pause, background }

    @Test("首个1秒UI采样前退出仍保存真实播放位置", arguments: Exit.allCases)
    func capturesClockBetweenUITicks(exit: Exit) async throws {
        try await withFixture { controller, store, articleID, root in
            let actual = try await advanceAndFreeze(controller)
            #expect(actual > 0.15)
            switch exit {
            case .close: controller.close()
            case .pause: controller.pause()
            case .background: controller.enterBackground()
            }
            let immediate = try #require(store.mediaProgress(articleID: articleID, attachmentKey: "primary"))
            #expect(abs(immediate.position - actual) < 0.1, "强制保存不能只取上一个1秒UI采样")
            try await store.flushPersistence()
            let reloaded = RSSStore(storageDirectory: root)
            let recovered = try #require(reloaded.mediaProgress(articleID: articleID, attachmentKey: "primary"))
            #expect(recovered.position == immediate.position)
        }
    }

    @Test("加载尚未就绪时关闭不覆盖原恢复位置")
    func loadingClosePreservesResumePosition() async throws {
        try await withFixture(initialPosition: 1.25) { controller, store, articleID, _ in
            controller.start()
            controller.close()
            #expect(store.mediaProgress(articleID: articleID, attachmentKey: "primary")?.position == 1.25)
        }
    }

    @Test("显式seek后立即退出保留用户目标，不被尚未完成的旧时钟覆盖", arguments: Exit.allCases)
    func seekThenExitPreservesRequestedPosition(exit: Exit) async throws {
        try await withFixture { controller, store, articleID, _ in
            _ = try await advanceAndFreeze(controller)
            controller.seek(to: 1.25)
            switch exit {
            case .close: controller.close()
            case .pause: controller.pause()
            case .background: controller.enterBackground()
            }
            #expect(store.mediaProgress(articleID: articleID, attachmentKey: "primary")?.position == 1.25)
        }
    }

    @Test("seek完成后强制保存重新读取已推进的真实时钟")
    func completedSeekResumesClockCapture() async throws {
        try await withFixture { controller, store, articleID, _ in
            _ = try await advanceAndFreeze(controller)
            let advanced = XCTestExpectation(description: "seek后推进到1.5秒")
            let token = controller.player.addBoundaryTimeObserver(
                forTimes: [NSValue(time: CMTime(seconds: 1.5, preferredTimescale: 600))], queue: .main) { advanced.fulfill() }
            defer { controller.player.removeTimeObserver(token) }
            controller.seek(to: 1.25)
            controller.resume()
            let result = await XCTWaiter.fulfillment(of: [advanced], timeout: 12)
            try #require(result == .completed)
            controller.close()
            #expect((store.mediaProgress(articleID: articleID, attachmentKey: "primary")?.position ?? 0) > 1.4)
        }
    }

    private func advanceAndFreeze(_ controller: VideoPlaybackController) async throws -> Double {
        let advanced = XCTestExpectation(description: "本地媒体推进0.25秒，无sleep或网络")
        let token = controller.player.addBoundaryTimeObserver(
            forTimes: [NSValue(time: CMTime(seconds: 0.25, preferredTimescale: 600))], queue: .main) { advanced.fulfill() }
        defer { controller.player.removeTimeObserver(token) }
        controller.start()
        let result = await XCTWaiter.fulfillment(of: [advanced], timeout: 12)
        try #require(result == .completed)
        controller.player.pause() // 固定比较时点，但不调用控制器的保存动作。
        return controller.player.currentTime().seconds
    }

    private func withFixture(initialPosition: Double = 0,
                             body: (VideoPlaybackController, RSSStore, String, URL) async throws -> Void) async throws {
        let key = UUID().uuidString
        // 每个用例一个独立RSSStore，不读取已有库。
        let root = URL.temporaryDirectory.appendingPathComponent("RSSProgressCapture-" + key)
        let store = RSSStore(storageDirectory: root)
        var source = RSSSource(name: "Progress capture fixture", url: "https://progress-fixture.invalid/" + key)
        source.importedFromLegado = true
        source.contentType = .video
        store.addSource(source)
        var item = RSSItem(id: key, title: "Progress fixture", link: "https://progress-fixture.invalid/episode", sourceId: source.id)
        item.contentType = .video
        store.mergeFetchedItems([item], for: source.id)
        let articleID = try #require(store.article(id: item.id)?.id)
        if initialPosition > 0 { store.updateMediaProgress(articleID: articleID, attachmentKey: "primary", position: initialPosition) }
        let stream = VideoStream(url: VideoStillFixtures.directory().appendingPathComponent("video-still-landscape.mp4"), headers: [:])
        let controller = VideoPlaybackController(rss: store, articleID: articleID, attachmentKey: "primary", stream: stream, title: "Progress fixture")
        defer { do { try FileManager.default.removeItem(at: root) } catch { Issue.record(error) } }
        do {
            try await body(controller, store, articleID, root)
            controller.close()
            try await store.flushPersistence()
        } catch {
            controller.close()
            try await store.flushPersistence()
            throw error
        }
    }
}
