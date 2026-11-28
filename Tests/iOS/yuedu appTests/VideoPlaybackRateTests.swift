import AVFoundation
import Foundation
import Observation
import Testing
@testable import yuedu_app

@MainActor
@Suite(.serialized, .timeLimit(.minutes(1)))
struct VideoPlaybackRateTests {
    @Test(arguments: [true, false])
    func longPressAndSelectedRateRespectTheAssetFormat(isHLS: Bool) async throws {
        let referer = "https://player.example/episode"
        let server = try VideoStillFixtureServer(directory: VideoStillFixtures.directory(), referer: referer)
        let base = try await server.start()
        defer { server.stop() }
        let url = base.appendingPathComponent(isHLS ? "video-still-hls.m3u8" : "video-still-landscape.mp4")
        let stream = VideoStream(url: url, headers: ["Referer": referer])
        let directory = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let owner = RSSStore(storageDirectory: directory)
        let controller = VideoPlaybackController(
            rss: owner, articleID: nil, attachmentKey: "rate-sample", stream: stream, title: "倍速样本"
        )
        defer { controller.close() }

        controller.start()
        try await waitWhile { controller.phase == .loading }
        try #require(controller.phase == .playing)
        try await waitWhile { controller.isStream == nil }
        let ceiling: Float = isHLS ? 2 : 3
        #expect(controller.isStream == isHLS)
        #expect(controller.offeredRates.last == ceiling)

        controller.setRate(1.25)
        controller.setLongPressing(true)
        #expect(controller.player.rate == ceiling)
        controller.setLongPressing(false)
        #expect(controller.player.rate == 1.25)

        controller.setRate(3)
        #expect(controller.player.defaultRate == ceiling)
        #expect(controller.player.rate == ceiling)
        controller.pause()
        controller.resume()
        #expect(controller.player.rate == ceiling)
        #expect(!server.requests.isEmpty && server.requests.allSatisfy { $0.referer == referer })
    }

    private func waitWhile(_ condition: () -> Bool) async throws {
        while condition() {
            try Task.checkCancellation()
            let (changes, announce) = AsyncStream<Void>.makeStream()
            withObservationTracking {
                _ = condition()
            } onChange: {
                announce.yield()
                announce.finish()
            }
            for await _ in changes { break }
        }
    }
}
