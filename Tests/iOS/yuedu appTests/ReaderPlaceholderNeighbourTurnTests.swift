import Foundation
import SwiftUI
import Testing
import UIKit
@testable import yuedu_app

@MainActor
@Suite(.serialized, .timeLimit(.minutes(1)))
struct ReaderPlaceholderNeighbourTurnTests {
    private struct Harness {
        let engine: CoreTextPageEngine
        let coordinator: CoreTextPageEngineView.Coordinator
        let pages: UIPageViewController
        let visible: UIViewController
    }

    private func makeHarness() async throws -> Harness {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let engine = CoreTextPageEngine(
            attributedBuilder: MockAttributedStringBuilder(texts: ["Opening page.", "Last page."]),
            renderSettings: EPUBTestFixtures.renderSettings(),
            offsetStore: CharOffsetStore(directoryURL: directory)
        )
        // 等首次章节字数扫描的通知，避免它替待测章节触发刷新。
        let (events, announce) = AsyncStream<Void>.makeStream()
        engine.onChapterReady = { if $0 == nil { announce.yield() } }
        await engine.start(renderSize: CGSize(width: 320, height: 480), bookId: UUID().uuidString)
        var iterator = events.makeAsyncIterator()
        _ = await iterator.next()
        announce.finish()
        try #require(engine.localPosition(for: 1).spineIndex == 1)

        let reader = CoreTextPageEngineView(
            engine: engine, pageTurnStyle: .slide, theme: .white, playbackHighlight: nil,
            isRTL: false, isDoublePageSpread: false, spreadGutter: 0,
            sessionCoordinator: nil, externalTargetVersion: 0, externalTargetPosition: nil,
            pageTurnCommand: nil, clearExternalTargetPosition: {}, currentPage: .constant(0),
            onPageChanged: { _, _ in }, onTapZone: { _ in }
        )
        let coordinator = reader.makeCoordinator()
        let pages = UIPageViewController(transitionStyle: .scroll, navigationOrientation: .horizontal)
        coordinator.bindEngineCallbacks(to: engine, pageViewController: pages)
        let visible = engine.pageViewController(at: 0)
        try #require(!(visible is PlaceholderPageViewController))
        pages.setViewControllers([visible], direction: .forward, animated: false)
        return Harness(engine: engine, coordinator: coordinator, pages: pages, visible: visible)
    }

    private func layOutLastChapter(in harness: Harness) async {
        _ = await harness.engine.preloadChapter(at: 1)
        // 通知使用主队列；等待先前已提交到队列的刷新回调。
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    @Test func turningBackFromAPlaceholderReplacesTheStaleNeighbour() async throws {
        let harness = try await makeHarness()
        let placeholder = harness.engine.pageViewController(at: 1)
        try #require(placeholder is PlaceholderPageViewController)
        harness.coordinator.pageViewController(
            harness.pages, didFinishAnimating: true, previousViewControllers: [placeholder], transitionCompleted: true
        )

        await layOutLastChapter(in: harness)

        #expect(harness.pages.viewControllers?.first !== harness.visible)
        #expect(!(harness.engine.pageViewController(at: 1) is PlaceholderPageViewController))
    }

    @Test func aTurnFromARealPageDoesNotRepaintAnUnrelatedChapter() async throws {
        let harness = try await makeHarness()
        harness.coordinator.pageViewController(
            harness.pages, didFinishAnimating: true,
            previousViewControllers: [harness.engine.pageViewController(at: 0)], transitionCompleted: true
        )

        await layOutLastChapter(in: harness)

        #expect(harness.pages.viewControllers?.first === harness.visible)
    }
}
