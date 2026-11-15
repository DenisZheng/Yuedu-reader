import Foundation
import SwiftUI
import UIKit
import XCTest
import Testing
@testable import yuedu_app

@Suite("评审RSS图片与列表呈现", .serialized)
@MainActor struct ReviewRSSPresentationTests {
    @Test("缩略图发送源头并执行文章上下文中的coverDecodeJs")
    func thumbnailUsesSharedContract() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = RSSStore(storageDirectory: directory)
        defer { cleanup(directory) }
        let bytes = try #require(png(size: .init(width: 24, height: 48)))
        let server = try VideoStillFixtureServer(directory: directory, routes: [
            "/image": .init(body: bytes, type: "image/png", requiredHeaders: ["x-fixture": "required"])
        ])
        let base = try await server.start(); defer { server.stop() }
        var source = RSSSource(name: "Fixture", url: base.appendingPathComponent("list").absoluteString)
        source.header = #"{"X-Fixture":"required"}"#
        source.coverDecodeJs = "if(rssArticle.title !== 'Article' || java.get('fixture') !== 'article') throw new Error('fixture context missing'); result.readAllBytes()"
        store.addSource(source)
        var article = RSSArticleRecord(item: RSSItem(id: "a", title: "Article", link: base.appendingPathComponent("article").absoluteString,
                                                   imageURL: base.appendingPathComponent("image").absoluteString, sourceId: source.id))
        article.variables = ["fixture": "article"]
        let session = URLSession(configuration: .ephemeral); defer { session.invalidateAndCancel() }
        let image = try await RSSImageService.thumbnail(article, source: source, owner: store, session: session)
        #expect(image.size.width == 24 && image.size.height == 48)
        #expect(server.requests.first?.headers["referer"] == base.appendingPathComponent("article").absoluteString)
        #expect(server.requests.count == 1)
        try await store.flushPersistence()
    }

    @Test("真实渲染0–4布局及认证缩略图，不以字段检查代替呈现", arguments: [0, 1, 2, 3, 4])
    func layoutsRender(_ rawStyle: Int) async throws {
        try await render(rawStyle, accessibility: false)
    }

    @Test("辅助功能大字号将三列呈现降为单列")
    func accessibilityIsSingleColumn() async throws { try await render(4, accessibility: true) }

    private func render(_ rawStyle: Int, accessibility: Bool) async throws {
        let presentation = try #require(RSSArticlePresentation(rawValue: rawStyle))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = RSSStore(storageDirectory: directory); defer { cleanup(directory) }
        let tall = try #require(png(size: .init(width: 24, height: 48)))
        let wide = try #require(png(size: .init(width: 48, height: 24)))
        let server = try VideoStillFixtureServer(directory: directory, routes: [
            "/tall": .init(body: tall, type: "image/png", requiredHeaders: ["x-fixture": "required"]),
            "/wide": .init(body: wide, type: "image/png", requiredHeaders: ["x-fixture": "required"])
        ])
        let base = try await server.start(); defer { server.stop() }
        var source = RSSSource(name: "Fixture", url: base.appendingPathComponent("list").absoluteString)
        source.header = #"{"X-Fixture":"required"}"#; source.articleStyle = rawStyle
        store.addSource(source)
        let count = presentation.isGrid && !accessibility ? 4 : 2
        let articles = (0..<count).map { index in RSSArticleRecord(item: RSSItem(id: "a\(index)", title: "Article \(index)", link: base.appendingPathComponent("article").absoluteString,
            imageURL: base.appendingPathComponent(index == 0 || index == 3 ? "tall" : "wide").absoluteString, sourceId: source.id)) }
        let capture = LayoutCapture(ids: articles.map(\.id), masonry: presentation == .masonry && !accessibility)
        let formatter = DateFormatter()
        let view = RSSArticleCollection(articles: articles, presentation: presentation, header: { EmptyView() }, footer: { EmptyView() }) { article in
            RSSArticleRow(source: source, article: article, timeFormatter: formatter, owner: store, presentation: presentation)
            .frame(maxWidth: .infinity)
            // 在条目处观察就绪信号；懒容器聚合偏好可能遗漏同一帧内最后一次图片更新。
            .onPreferenceChange(RSSArticleThumbnail.ReadyImages.self) { ids in Task { @MainActor in capture.acceptImages(ids) } }
            .background { GeometryReader { geometry in Color.clear.preference(key: Frames.self, value: [article.id: geometry.frame(in: .named("fixture"))]) } }
        }
        .coordinateSpace(name: "fixture")
        .environment(\.dynamicTypeSize, accessibility ? .accessibility3 : .large)
        .onPreferenceChange(Frames.self) { frames in Task { @MainActor in capture.accept(frames) } }
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 360, height: 880)
        window.rootViewController = UIHostingController(rootView: view)
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKey() }
        let verdict = await XCTWaiter.fulfillment(of: [capture.ready], timeout: 10)
        #expect(verdict == .completed)
        let frames = try #require(capture.frames)
        let first = try #require(frames[articles[0].id]); let second = try #require(frames[articles[1].id])
        let expected = presentation.columns(in: window.bounds.size, accessibility: accessibility)
        if expected == 1 { #expect(abs(first.minX - second.minX) < 1 && second.minY > first.minY) }
        else { #expect(second.minX > first.minX) }
        if rawStyle == 4, !accessibility {
            let third = try #require(frames[articles[2].id]); #expect(third.minX > second.minX)
        }
        let renderer = UIGraphicsImageRenderer(bounds: window.bounds)
        let screenshot = renderer.image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
        if #available(iOS 26.0, *), let data = screenshot.pngData() {
            Attachment.record(data, named: "rss-style-\(rawStyle)-\(accessibility ? "AX" : "normal").png")
        }
        try await store.flushPersistence()
    }

    private func png(size: CGSize) -> Data? {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.preferredRange = .standard
        return UIGraphicsImageRenderer(size: size, format: format).image { context in UIColor.systemBlue.setFill(); context.fill(CGRect(origin: .zero, size: size)) }.pngData()
    }
    private func cleanup(_ directory: URL) {
        if FileManager.default.fileExists(atPath: directory.path) {
            do { try FileManager.default.removeItem(at: directory) } catch { Issue.record(error) }
        }
    }
    private struct Frames: PreferenceKey {
        static let defaultValue: [String: CGRect] = [:]
        static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) { value.merge(nextValue(), uniquingKeysWith: { _, new in new }) }
    }
    private final class LayoutCapture {
        let ready = XCTestExpectation(description: "收到实际布局")
        let ids: [String]
        let masonry: Bool
        var frames: [String: CGRect]?
        private var latestFrames: [String: CGRect] = [:]
        private var readyImages: Set<String> = []
        init(ids: [String], masonry: Bool) { self.ids = ids; self.masonry = masonry }
        func accept(_ value: [String: CGRect]) { latestFrames = value; check() }
        // 本次冻结的条目/请求不变：完成信号只累积，避免SwiftUI分支布局发出较旧的偏好覆盖已完成图片。
        func acceptImages(_ value: Set<String>) { readyImages.formUnion(value); check() }
        private func check() {
            guard frames == nil, ids.allSatisfy({ latestFrames[$0] != nil && readyImages.contains($0) }) else { return }
            if masonry {
                guard let third = latestFrames[ids[2]], let fourth = latestFrames[ids[3]], third.minY - fourth.minY > 40 else { return }
            }
            frames = latestFrames; ready.fulfill()
        }
    }
}
