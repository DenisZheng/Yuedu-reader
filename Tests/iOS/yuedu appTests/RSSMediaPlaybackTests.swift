import AVFoundation
import Foundation
import SwiftUI
import Testing
import UIKit
import XCTest
@testable import yuedu_app

@Suite("RSS persisted attachment media", .serialized)
@MainActor struct RSSMediaPlaybackTests {
    private var fixtures: URL { VideoStillFixtures.directory() }

    @Test("feed attachment materializes into stable RSS-owned typed media, never a signed-URL progress key")
    func attachmentMaterialization() async throws {
        let parsed = ParsedFeedItem(uniqueID: "article", feedURL: "https://feed.invalid/rss", url: "https://feed.invalid/article",
            externalURL: nil, title: "Video", language: nil, contentHTML: nil, contentText: nil, summary: nil,
            imageURL: nil, bannerImageURL: nil, datePublished: nil, dateModified: nil, authors: nil, tags: nil,
            attachments: [ParsedAttachment(url: "../media/episode.mp4?token=one", mimeType: "video/mp4", title: "Episode", sizeInBytes: 1024, durationInSeconds: 10)!])
        let first = RSSItem(from: parsed, sourceId: "source")
        let reference = try #require(first.media?.first)
        #expect(first.contentType == nil, "普通Feed附件不改变安全文章入口")
        #expect(RSSItem(from: parsed, sourceId: "source", sourceContentType: .video).contentType == .video)
        #expect(reference.kind == .video)
        #expect(reference.url == "https://feed.invalid/media/episode.mp4?token=one")
        #expect(reference.key == "attachment:0:2:video/mp4")
        var renewed = parsed
        renewed.attachments = [ParsedAttachment(url: "../media/episode.mp4?token=two", mimeType: "video/mp4", title: "Episode", sizeInBytes: 1024, durationInSeconds: 10)!]
        #expect(RSSItem(from: renewed, sourceId: "source").media?.first?.key == reference.key)
        #expect(RSSItem(from: renewed, sourceId: "source").media?.first?.url.contains("token=two") == true)
    }

    @Test("RSS媒体切后台停止且不开画中画；后台就绪/锁屏命令不重启，回前台不自动续播")
    func backgroundStopsPlayback() async throws {
        let directory = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let owner = RSSStore(storageDirectory: directory)
        defer {
            // 本用例不写RSS状态，目录可能从未创建；只清理实际存在的临时目录。
            if FileManager.default.fileExists(atPath: directory.path) {
                do { try FileManager.default.removeItem(at: directory) } catch { Issue.record(error) }
            }
        }
        let stream = VideoStream(url: fixtures.appendingPathComponent("video-still-landscape.mp4"), headers: [:])
        let controller = VideoPlaybackController(rss: owner, articleID: nil, attachmentKey: "primary", stream: stream, title: "Foreground")
        #expect(!controller.allowsPictureInPicture)
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        let host = UIViewController()
        window.rootViewController = host
        let layer = AVPlayerLayer(player: controller.player)
        layer.frame = CGRect(x: 0, y: 0, width: 320, height: 180)
        host.view.layer.addSublayer(layer)
        window.isHidden = false
        defer { layer.player = nil; window.isHidden = true; controller.close() }
        controller.start()
        let advanced = XCTestExpectation(description: "前台实际播放")
        let observer = controller.player.addBoundaryTimeObserver(forTimes: [NSValue(time: CMTime(seconds: 0.5, preferredTimescale: 600))], queue: .main) { advanced.fulfill() }
        defer { controller.player.removeTimeObserver(observer) }
        #expect(await XCTWaiter.fulfillment(of: [advanced], timeout: 12) == .completed)
        controller.enterBackground()
        #expect(controller.phase == .paused)
        #expect(controller.player.rate == 0)
        controller.resume()
        #expect(controller.phase == .paused, "后台的锁屏命令不能重新播放")
        #expect(controller.player.rate == 0)
        controller.enterForeground()
        #expect(controller.phase == .paused, "回前台不自动续播")
        controller.resume()
        #expect(controller.phase == .playing)
        #expect(controller.player.rate > 0)
    }

    @Test("type=2文章经真实阅读页进入播放器并实际推进，离开写进度；凭据撤销停止播放")
    func readerPagePlaysAndRevokes() async throws {
        let directory = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { do { try FileManager.default.removeItem(at: directory) } catch { Issue.record(error) } }
        let owner = RSSStore(storageDirectory: directory)
        let referer = "https://fixture.invalid/typed"
        let server = try VideoStillFixtureServer(directory: fixtures, referer: referer)
        let base = try await server.start()
        defer { server.stop() }
        var source = RSSSource(name: "Typed page", url: base.absoluteString)
        source.importedFromLegado = true; source.contentType = .video
        source.header = #"{"Referer":"https://fixture.invalid/typed"}"#
        owner.addSource(source)
        var item = RSSItem(id: "typed-page", title: "Typed page", link: base.appendingPathComponent("video-still-landscape.mp4").absoluteString, sourceId: source.id)
        item.contentType = .video
        owner.mergeFetchedItems([item], for: source.id)
        let articleID = try #require(owner.article(id: item.id)).id
        func open() throws -> UIWindow {
            let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
            let window = UIWindow(windowScene: scene)
            window.rootViewController = UIHostingController(rootView: NavigationStack {
                RSSArticleReaderView(articleID: articleID, store: owner)
            }.environmentObject(BookStore(metadataFileURL: directory.appendingPathComponent("books.json"))))
            window.makeKeyAndVisible()
            return window
        }
        func player(in view: UIView) -> AVPlayer? {
            func search(_ layer: CALayer) -> AVPlayer? {
                if let value = (layer as? AVPlayerLayer)?.player { return value }
                return layer.sublayers?.lazy.compactMap(search).first
            }
            return search(view.layer)
        }
        func waitForPlayer(_ window: UIWindow) async throws -> AVPlayer {
            let deadline = ContinuousClock.now + .seconds(12)
            while ContinuousClock.now < deadline {
                if let value = player(in: window), value.currentItem != nil { return value }
                await Task.yield()
            }
            throw RSSWebFailure.resourceUnavailable
        }
        func advance(_ value: AVPlayer) async {
            let start = value.currentTime().seconds
            let moved = XCTestExpectation(description: "真实页面播放推进")
            let target = CMTime(seconds: start + 0.5, preferredTimescale: 600)
            let token = value.addBoundaryTimeObserver(forTimes: [NSValue(time: target)], queue: .main) { moved.fulfill() }
            #expect(await XCTWaiter.fulfillment(of: [moved], timeout: 12) == .completed)
            value.removeTimeObserver(token)
        }
        do {
            let window = try open()
            let value = try await waitForPlayer(window)
            await advance(value)
            #expect(server.requests.allSatisfy { $0.referer == referer })
            window.isHidden = true; window.rootViewController = nil
            let deadline = ContinuousClock.now + .seconds(5)
            while owner.mediaProgress(articleID: articleID, attachmentKey: "primary") == nil, ContinuousClock.now < deadline { await Task.yield() }
            #expect((owner.mediaProgress(articleID: articleID, attachmentKey: "primary")?.position ?? 0) > 0)
            let again = try open()
            defer { again.isHidden = true; again.rootViewController = nil }
            let reopened = try await waitForPlayer(again)
            await advance(reopened)
            owner.authenticationChanged(for: source.id)
            let cleared = ContinuousClock.now + .seconds(5)
            while reopened.currentItem != nil, ContinuousClock.now < cleared { await Task.yield() }
            #expect(reopened.currentItem == nil, "凭据撤销后旧播放器必须停止")
        } catch { try await owner.flushPersistence(); throw error }
        try await owner.flushPersistence()
    }

    @Test("type=2 ruleContent produces the playable URL (relative to the article); type=1 empty rule uses the link")
    func typedArticleResourceURL() async throws {
        let directory = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let owner = RSSStore(storageDirectory: directory)
        let server = try VideoStillFixtureServer(directory: fixtures, routes: [
            "/x/article": .init(body: Data("<a id='v' href='../media/video-still-landscape.mp4'>v</a>".utf8), type: "text/html")
        ])
        let base = try await server.start()
        defer {
            server.stop()
            do { try FileManager.default.removeItem(at: directory) } catch { Issue.record(error) }
        }
        var source = RSSSource(name: "Typed", url: base.absoluteString)
        source.importedFromLegado = true; source.contentType = .video; source.ruleContent = "id.v@href"
        owner.addSource(source)
        var item = RSSItem(id: "typed", title: "Typed", link: base.appendingPathComponent("x/article").absoluteString, sourceId: source.id)
        item.contentType = .video
        owner.mergeFetchedItems([item], for: source.id)
        let article = try #require(owner.article(id: item.id))
        #expect(try await RSSTypedArticleModel.resourceURL(article, source: source, owner: owner)
                == base.appendingPathComponent("media/video-still-landscape.mp4").absoluteString)
        #expect(server.requests.filter { $0.path == "/x/article" }.count == 1, "type=2 resolves only the first content page")
        #expect(RSSTypedArticleModel.absolute("../media/a.mp4", base: "https://h.invalid/x/y/article") == "https://h.invalid/x/media/a.mp4")
        #expect(RSSTypedArticleModel.absolute("javascript:void(0)", base: "https://h.invalid/") == "")
        var image = source; image.ruleContent = nil; image.contentType = .image
        var imageItem = RSSArticleRecord(item: item); imageItem.contentType = .image
        #expect(try await RSSTypedArticleModel.resourceURL(imageItem, source: image, owner: owner) == item.link)
        try await owner.flushPersistence()
    }

    @Test("production RSS media AnalyzeUrl headers reach actual HLS playlist/segments and AVPlayer; article progress survives reopen")
    func hlsPlaybackPersistsProgress() async throws {
        let directory = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let owner = RSSStore(storageDirectory: directory)
        let referer = "https://fixture.invalid/rss/article"
        let server = try VideoStillFixtureServer(directory: fixtures, referer: referer)
        let base = try await server.start()
        defer {
            server.stop()
            do { try FileManager.default.removeItem(at: directory) } catch { Issue.record(error) }
        }
        var source = RSSSource(name: "RSS video", url: base.absoluteString)
        source.header = #"{"Referer":"https://fixture.invalid/rss/article"}"#
        source.enabledCookieJar = true
        owner.addSource(source)
        var item = RSSItem(id: "episode", title: "Episode", link: base.appendingPathComponent("video-still-hls.m3u8").absoluteString, sourceId: source.id)
        item.contentType = .video
        item.media = [.init(key: "attachment:0:2:application/vnd.apple.mpegurl", articleID: item.id, kind: .video,
                            url: base.appendingPathComponent("video-still-hls.m3u8").absoluteString)]
        owner.mergeFetchedItems([item], for: source.id)
        let article = try #require(owner.article(id: item.id))
        let media = try #require(article.media?.first)
        let prepared = try await RSSMediaRequestService.prepare(media.url, source: source, base: URL(string: article.link),
                                                                 context: nil, owner: owner, trustedRuleURL: false)
        #expect(prepared.request.value(forHTTPHeaderField: "Referer") == referer)
        let (stream, resourceSession) = try await RSSMediaRequestService.stream(prepared)
        #expect(stream.headers.isEmpty, "privileged upstream headers are never placed on an asset-wide player request")
        #expect(stream.url.path != URL(string: media.url)!.path, "the source address is only available through the session capability")
        #expect(server.requests.isEmpty, "no upstream bytes are fetched before the player asks")

        let first = VideoPlaybackController(rss: owner, articleID: article.id, attachmentKey: media.key,
                                            stream: stream, title: article.title, resources: resourceSession)
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        let host = UIViewController()
        window.rootViewController = host
        let layer = AVPlayerLayer(player: first.player)
        layer.frame = CGRect(x: 0, y: 0, width: 320, height: 180)
        host.view.layer.addSublayer(layer)
        window.isHidden = false
        defer { layer.player = nil; window.isHidden = true }
        first.start()
        let advanced = XCTestExpectation(description: "RSS AVPlayer advances past one second")
        let observer = first.player.addBoundaryTimeObserver(forTimes: [NSValue(time: CMTime(seconds: 1, preferredTimescale: 600))], queue: .main) {
            advanced.fulfill()
        }
        defer { first.player.removeTimeObserver(observer) }
        let waitResult = await XCTWaiter.fulfillment(of: [advanced], timeout: 12)
        #expect(waitResult == .completed)
        #expect(first.phase == .playing || first.currentTime >= 1)
        #expect(first.currentTime >= 1)
        #expect(server.requests.allSatisfy { $0.headers["referer"] == referer })
        #expect(server.requests.contains { $0.path.hasSuffix("video-still-hls.m3u8") })
        #expect(server.requests.contains { $0.path.hasSuffix(".m4s") })
        first.saveProgress(force: true)
        first.close()
        resourceSession.stop()
        try await owner.flushPersistence()
        let saved = try #require(owner.mediaProgress(articleID: article.id, attachmentKey: media.key))
        #expect(saved.position >= 1)

        let reopened = VideoPlaybackController(rss: owner, articleID: article.id, attachmentKey: media.key,
                                               stream: stream, title: article.title)
        #expect(abs(reopened.book.audioTimeSeconds - saved.position) < 0.01)
        reopened.close()
        try await owner.flushPersistence()
        let restored = RSSStore(storageDirectory: directory)
        #expect(restored.mediaProgress(articleID: article.id, attachmentKey: media.key)?.position == saved.position,
                "未开始的恢复页面关闭不能将真实进度覆盖为零")
    }
}
