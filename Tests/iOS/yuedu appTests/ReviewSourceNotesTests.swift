import SwiftUI
import UIKit
import Vision
import XCTest
import Testing
@testable import yuedu_app

@Suite("评审来源说明呈现", .serialized)
@MainActor struct ReviewSourceNotesTests {
    @Test("源作者说明实际显示在原生设置页，不只存储字段")
    func sourceCommentIsVisible() async throws {
        let directory = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = RSSStore(storageDirectory: directory)
        defer { if FileManager.default.fileExists(atPath: directory.path) {
            do { try FileManager.default.removeItem(at: directory) } catch { Issue.record(error) }
        } }
        var source = RSSSource(name: "Fixture", url: "https://fixture.invalid/rss")
        source.sourceComment = "Fixture source note"
        store.addSource(source)
        let ready = XCTestExpectation(description: "原生说明页已显示")
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView:
            NavigationStack { RSSSourceSettingsView(sourceID: source.id, store: store) }
                .environment(\.dynamicTypeSize, .large).environment(\.colorScheme, .light)
                .onAppear { ready.fulfill() })
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKey() }
        #expect(await XCTWaiter.fulfillment(of: [ready], timeout: 5) == .completed)
        window.layoutIfNeeded()
        let screenshot = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let data = try #require(screenshot.pngData())
        let words = try await Task.detached {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate; request.recognitionLanguages = ["en-US"]
            request.usesLanguageCorrection = false
            try VNImageRequestHandler(data: data, orientation: .up, options: [:]).perform([request])
            return request.results?.compactMap { $0.topCandidates(1).first?.string } ?? []
        }.value
        #expect(words.contains { $0.lowercased().contains("fixture source note") })
        if #available(iOS 26.0, *) { Attachment.record(data, named: "rss-source-note.png") }
        try await store.flushPersistence()
    }
}
