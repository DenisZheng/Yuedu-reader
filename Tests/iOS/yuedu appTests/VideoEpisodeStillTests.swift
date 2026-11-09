import CoreImage
import Foundation
import Testing
import UIKit
@testable import yuedu_app

/// 選集's episode stills (maintainer, 2026-11-01: 「做，只截看得到的幾集」). The clips are black
/// for their first second and blue after it, ten seconds in all, so a still taken a fifth of
/// the way in is blue and one taken at the first frame is black.
@Suite("Video episode stills")
struct VideoEpisodeStillTests {
    private static let fixtures = VideoStillFixtures.directory()
    private static let card = CGSize(width: 672, height: 378)

    private func still(_ name: String) async throws -> VideoStillFrame {
        let stream = VideoStream(url: Self.fixtures.appendingPathComponent(name), headers: [:])
        return try await VideoStillExtractor.still(of: stream, fitting: Self.card)
    }

    private func image(_ frame: VideoStillFrame) throws -> CGImage {
        try #require(UIImage(data: frame.jpeg)?.cgImage)
    }

    /// The colour at the frame's centre.
    private func centre(_ image: CGImage) -> (red: Double, green: Double, blue: Double) {
        var pixel = [UInt8](repeating: 0, count: 4)
        let context = CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        context?.interpolationQuality = .none
        context?.draw(image, in: CGRect(x: -CGFloat(image.width) / 2, y: -CGFloat(image.height) / 2,
                                        width: CGFloat(image.width), height: CGFloat(image.height)))
        return (Double(pixel[0]) / 255, Double(pixel[1]) / 255, Double(pixel[2]) / 255)
    }

    @Test("a file's still is taken past its first frame, with its running time")
    func fileStill() async throws {
        let frame = try await still("video-still-landscape.mp4")
        let image = try image(frame)
        #expect(image.width == 320 && image.height == 180, "never scaled up past the stream's own size")
        let colour = centre(image)
        #expect(colour.blue > 0.6 && colour.red < 0.3, "the first second is black; a fifth in is blue")
        #expect(abs((frame.duration ?? 0) - 10) < 0.5)
        #expect(VideoStillCoding.duration(in: frame.jpeg) == frame.duration)
    }

    /// Served, not read from disk: iOS's player never readies an HLS playlist from a file
    /// (measured 2026-11-01: `.unknown` after 8 s, where the same playlist over HTTP is ready
    /// in under one).
    @Test("an HLS playlist behind a Referer check gives a still, every request carrying the stream's headers")
    func playlistStill() async throws {
        let referer = "https://v.example/play/1"
        let server = try VideoStillFixtureServer(directory: Self.fixtures, referer: referer)
        let base = try await server.start()
        defer { server.stop() }
        let stream = VideoStream(url: base.appendingPathComponent("video-still-hls.m3u8"), headers: ["Referer": referer])
        let frame = try await VideoStillExtractor.still(of: stream, fitting: Self.card)
        let colour = centre(try image(frame))
        #expect(colour.blue > 0.6 && colour.red < 0.3)
        #expect(abs((frame.duration ?? 0) - 10) < 0.5)
        let requests = server.requests
        #expect(requests.contains { $0.path.hasSuffix(".m4s") }, "a segment was fetched, not only the playlist")
        #expect(requests.allSatisfy { $0.referer == referer }, "\(requests)")
    }

    @Test("a portrait episode stays portrait")
    func portraitStill() async throws {
        let image = try image(try await still("video-still-portrait.mp4"))
        #expect(image.height > image.width)
    }

    @Test("an audio-only episode has no still")
    func audioOnly() async throws {
        await #expect(throws: VideoStillError.noFrame) {
            _ = try await still("video-still-audio-only.m4a")
        }
    }

    @Test("a large frame is scaled down until it just covers the card")
    func scaledToCover() throws {
        let large = CIImage(color: CIColor(red: 0, green: 0, blue: 1)).cropped(to: CGRect(x: 0, y: 0, width: 1920, height: 1080))
        let jpeg = try #require(VideoStillCoding.jpeg(of: large, fitting: Self.card, duration: 2712.5))
        let image = try #require(UIImage(data: jpeg)?.cgImage)
        #expect(image.width == 672 && image.height == 378)
        #expect(VideoStillCoding.duration(in: jpeg) == 2712.5)
        #expect(VideoStillCoding.duration(in: try #require(VideoStillCoding.jpeg(of: large, fitting: Self.card, duration: nil))) == nil)
    }

    @Test("a quarter-turn track stands upright")
    func rotation() {
        #expect(VideoStillExtractor.orientation(of: CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 1080, ty: 0)) == .right)
        #expect(VideoStillExtractor.orientation(of: CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: 1920)) == .left)
        #expect(VideoStillExtractor.orientation(of: CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: 1920, ty: 1080)) == .down)
        #expect(VideoStillExtractor.orientation(of: .identity) == .up)
    }

    @Test("running time in whole minutes, never 0")
    func minutes() {
        #expect(VideoEpisodeRunningTime.minutes(20) == 1)
        #expect(VideoEpisodeRunningTime.minutes(81) == 1)
        #expect(VideoEpisodeRunningTime.minutes(150) == 3)
        #expect(VideoEpisodeRunningTime.minutes(2712.5) == 45)
    }

    @Test("a still is keyed by its source and episode address, not by a stream or a book")
    func key() {
        let source = UUID()
        #expect(VideoEpisodeStills.key(sourceId: source, chapterURL: "/ep/1")
            == VideoEpisodeStills.key(sourceId: source, chapterURL: "/ep/1"))
        #expect(VideoEpisodeStills.key(sourceId: source, chapterURL: "/ep/1")
            != VideoEpisodeStills.key(sourceId: source, chapterURL: "/ep/2"))
        #expect(VideoEpisodeStills.key(sourceId: source, chapterURL: "/ep/1")
            != VideoEpisodeStills.key(sourceId: UUID(), chapterURL: "/ep/1"))
    }

    @Test("episodes run in thirties under the row, named by their episode numbers")
    func ranges() {
        let runs = VideoEpisodeRange.ranges(of: Array(10..<47)) { $0 - 9 }
        #expect(runs.map { "\($0.firstNumber)·\($0.lastNumber)" } == ["1·30", "31·37"])
        #expect(runs[1].episodes.first == 40 && runs[1].id == 40)
        #expect(VideoEpisodeRange.ranges(of: Array(0..<30)) { $0 + 1 }.count == 1)
        #expect(VideoEpisodeRange.ranges(of: []) { $0 }.isEmpty)
    }

    @Test("only a failure the episode itself causes is remembered; a network one is asked again")
    func rememberedFailures() {
        #expect(VideoEpisodeStills.failsEveryTime(VideoStillError.noFrame))
        #expect(VideoEpisodeStills.failsEveryTime(VideoChapterLinkError.dashManifest))
        #expect(VideoEpisodeStills.failsEveryTime(VideoChapterLinkError.noVideoOnPage))
        #expect(!VideoEpisodeStills.failsEveryTime(VideoStillError.timedOut))
        #expect(!VideoEpisodeStills.failsEveryTime(URLError(.notConnectedToInternet)))
        #expect(!VideoEpisodeStills.failsEveryTime(VideoChapterLinkError.notALink(preview: "")))
        #expect(!VideoEpisodeStills.failsEveryTime(CancellationError()))
    }

    @Test("an unshelved video keeps one id per work across visits")
    func unshelvedID() {
        let source = UUID()
        let id = UUID.unshelvedVideoID(sourceId: source, bookURL: "https://v.example/1")
        #expect(id == UUID.unshelvedVideoID(sourceId: source, bookURL: "https://v.example/1"))
        #expect(id != UUID.unshelvedVideoID(sourceId: source, bookURL: "https://v.example/2"))
        #expect(id != UUID.unshelvedVideoID(sourceId: UUID(), bookURL: "https://v.example/1"))
        #expect(ReadingBook(id: id, title: "x", contentFilename: "").id == id)
    }

    @Test("a still waiting for a slot stops waiting when its card leaves")
    func gateWaitIsCancellable() async throws {
        let gate = VideoStillGate(limit: 1)
        try await gate.enter()
        let waiter = Task { try await gate.enter() }
        while await gate.waitingCount == 0 { await Task.yield() }
        waiter.cancel()
        await #expect(throws: CancellationError.self) { try await waiter.value }
        #expect(await gate.waitingCount == 0)
        #expect(await gate.runningCount == 1)
        await gate.leave()
        #expect(await gate.runningCount == 0)
    }

    @Test("a slot freed goes to the next still waiting")
    func gateHandsOver() async throws {
        let gate = VideoStillGate(limit: 1)
        try await gate.enter()
        let waiter = Task { try await gate.enter() }
        while await gate.waitingCount == 0 { await Task.yield() }
        await gate.leave()
        try await waiter.value
        #expect(await gate.runningCount == 1)
        #expect(await gate.waitingCount == 0)
    }
}
