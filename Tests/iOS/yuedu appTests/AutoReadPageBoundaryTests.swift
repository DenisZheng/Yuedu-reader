import SwiftUI
import Testing
import UIKit
@testable import yuedu_app

/// 固定帧输入与实际图层绘制；不调用旧 suite 清除全局速度偏好的辅助函数。
@MainActor
@Suite("自动阅读页面边界", .serialized)
struct AutoReadPageBoundaryTests {
    @Test("页面未落地前揭页保持完整，不露出刚读过的页面")
    func holdsRevealUntilPageLands() {
        let controller = AutoReadController()
        defer { controller.stopForReaderExit() }
        var turns = 0
        controller.onAdvancePage = { turns += 1; return true }
        controller.enter()
        controller.step(elapsed: controller.secondsPerPage)
        #expect(turns == 1)
        #expect(controller.progress == 1)
        controller.step(elapsed: controller.secondsPerPage)
        #expect(turns == 1)
        #expect(controller.progress == 1)
    }

    @Test("落地后计入已读时间，重复或手动翻页后的回报不改变进度")
    func resolvedTurnPreservesElapsedTime() {
        let controller = AutoReadController()
        defer { controller.stopForReaderExit() }
        controller.onAdvancePage = { true }
        controller.enter()
        controller.step(elapsed: controller.secondsPerPage * 1.1)
        controller.step(elapsed: controller.secondsPerPage * 0.05)
        controller.pageTurnResolved()
        #expect(abs(controller.progress - 0.15) < 1e-9)
        #expect(!controller.isAwaitingPageTurn)
        controller.pageTurnResolved()
        #expect(abs(controller.progress - 0.15) < 1e-9)
        controller.step(elapsed: controller.secondsPerPage)
        controller.resetReveal()
        controller.step(elapsed: controller.secondsPerPage * 0.1)
        controller.pageTurnResolved()
        #expect(abs(controller.progress - 0.1) < 1e-9)
    }

    @Test("慢转场不跳过未显示的页面，退出清理等待")
    func slowTurnDoesNotSkipPages() {
        let controller = AutoReadController()
        defer { controller.stopForReaderExit() }
        var turns = 0
        controller.onAdvancePage = { turns += 1; return true }
        controller.enter()
        controller.step(elapsed: controller.secondsPerPage)
        controller.step(elapsed: controller.secondsPerPage * 3.5)
        #expect(turns == 1)
        controller.pageTurnResolved()
        #expect(controller.progress == 1)
        controller.step(elapsed: controller.secondsPerPage * 0.01)
        #expect(turns == 2)
        controller.stopForReaderExit()
        controller.pageTurnResolved()
        #expect(!controller.isAwaitingPageTurn && controller.progress == 0)
    }

    @Test("暂停不推进等待，切换滚动模式结束分页等待，书末退出")
    func pauseScrollAndLastPage() {
        let controller = AutoReadController()
        defer { controller.stopForReaderExit() }
        controller.onAdvancePage = { true }
        var scroll = false
        var distance = 0.0
        controller.usesContinuousScroll = { scroll }
        controller.onScrollByFraction = { distance += $0; return true }
        controller.enter()
        controller.step(elapsed: controller.secondsPerPage)
        controller.pause()
        controller.step(elapsed: controller.secondsPerPage)
        #expect(controller.progress == 1)
        controller.resume()
        scroll = true
        controller.step(elapsed: controller.secondsPerPage * 0.1)
        #expect(!controller.isAwaitingPageTurn && abs(distance - 0.1) < 1e-9)
        controller.exit()
        scroll = false
        controller.onAdvancePage = { false }
        controller.enter()
        controller.step(elapsed: controller.secondsPerPage)
        #expect(!controller.isActive && !controller.isAwaitingPageTurn && controller.progress == 0)
    }

    @Test("三种分页宿主等待时保持当前图片，回报后才替换下一页", arguments: [PageTurnStyle.curl, .cover, .slide])
    func hostKeepsPictureUntilResolved(_ style: PageTurnStyle) async throws {
        let size = CGSize(width: 320, height: 480)
        let settings = ReaderRenderSettings(
            theme: "light", textColor: .black, backgroundColor: .white,
            fontSize: 18, lineHeightMultiple: 1.4, lineSpacing: 4, paragraphSpacing: 6,
            letterSpacing: 0, marginH: 24, marginV: 16, footerHeight: 16,
            contentInsets: UIEdgeInsets(top: 24, left: 24, bottom: 48, right: 24)
        )
        let engine = CoreTextPageEngine(
            attributedBuilder: AutoReadFixtureBuilder(), renderSettings: settings,
            offsetStore: CharOffsetStore(directoryURL: URL.temporaryDirectory.appendingPathComponent("auto-read-" + UUID().uuidString))
        )
        await engine.start(renderSize: size, bookId: UUID().uuidString)
        await engine.preloadChapter(at: 0)
        try #require(engine.totalPages > 2)
        let coordinator = CoreTextPageEngineView.Coordinator(
            engine: engine, pageTurnStyle: style, theme: .white, playbackHighlight: nil,
            isRTL: false, isDoublePageSpread: false, spreadGutter: 0, sessionCoordinator: nil,
            externalTargetPosition: nil, clearExternalTargetPosition: {}, currentPage: .constant(0),
            onPageChanged: { _, _ in }, onTapZone: { _ in }
        )
        let host = UIPageViewController(transitionStyle: .scroll, navigationOrientation: .horizontal)
        host.view.frame = CGRect(origin: .zero, size: size)
        let handle = ReaderAutoReadRevealHandle()
        let controller = AutoReadController()
        defer { controller.stopForReaderExit() }
        var imageAtReset: Int?
        handle.onPageTurnResolved = {
            imageAtReset = coordinator.autoReadRevealView.imagePageIndex
            controller.pageTurnResolved()
        }
        coordinator.applyAutoReadReveal(page: 0, handle: handle, turnArriving: false, on: host)
        try #require(!coordinator.autoReadRevealView.isHidden)
        controller.onProgressChanged = { handle.setProgress?($0) }
        controller.onAdvancePage = { true }
        controller.enter()
        controller.step(elapsed: controller.secondsPerPage)
        coordinator.autoReadTurn = .queued
        coordinator.applyAutoReadReveal(page: 1, handle: handle, turnArriving: true, on: host)
        #expect(coordinator.autoReadRevealView.imagePageIndex == 0)
        #expect(controller.progress == 1)
        coordinator.resolveAutoReadTurn()
        #expect(imageAtReset == 0)
        #expect(coordinator.autoReadRevealView.imagePageIndex == 1)
        #expect(!coordinator.autoReadRevealView.isHidden)
        #expect(!controller.isAwaitingPageTurn && controller.progress == 0)
    }

    @Test("仿真后来加入的新页面不能盖住揭页图层")
    func revealDrawsAboveLaterPage() async throws {
        let bounds = CGRect(x: 0, y: 0, width: 32, height: 32)
        let host = UIView(frame: bounds)
        let reveal = AutoReadRevealView(frame: bounds)
        let blue = UIGraphicsImageRenderer(bounds: bounds).image { context in
            context.cgContext.setFillColor(UIColor.blue.cgColor)
            context.cgContext.fill(bounds)
        }
        reveal.setPageImage(blue, pageIndex: 1)
        reveal.setProgress(1)
        host.addSubview(reveal)
        let laterPage = UIView(frame: bounds)
        laterPage.backgroundColor = .red
        host.addSubview(laterPage)
        let ready = AsyncStream<Void>.makeStream()
        defer { ready.continuation.finish() }
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousWindow = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: AutoReadDrawingHost(view: host)
            .frame(width: bounds.width, height: bounds.height)
            .onAppear { ready.continuation.yield(()) })
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true; window.rootViewController = nil
            previousWindow?.makeKeyAndVisible()
        }
        var iterator = ready.stream.makeAsyncIterator()
        _ = await iterator.next()
        let configuredZ = reveal.layer.zPosition
        // 真实窗口快照反映屏幕合成；离屏 layer.render 不能代表这里的图层覆盖结果。
        func pixel() throws -> [UInt8] {
            var drew = false
            let image = UIGraphicsImageRenderer(bounds: bounds).image { context in
                drew = host.drawHierarchy(in: bounds, afterScreenUpdates: true)
            }
            try #require(drew)
            var pixels = [UInt8](repeating: 0, count: 4)
            try pixels.withUnsafeMutableBytes { bytes in
                let context = try #require(CGContext(
                    data: bytes.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
                ))
                context.draw(try #require(image.cgImage), in: CGRect(x: 0, y: 0, width: 1, height: 1))
            }
            return pixels
        }
        reveal.layer.zPosition = 0
        let control = try pixel()
        #expect(control[0] > control[2], "控制组应被后来加入的红色页面盖住")
        reveal.layer.zPosition = configuredZ
        let result = try pixel()
        #expect(result[2] > result[0], "生产配置应显示蓝色揭页，而不是后来加入的红色页面")
    }
}

/// 仅用于把固定图层 fixture 挂到真实窗口，等待实际出现事件。
private struct AutoReadDrawingHost: UIViewRepresentable {
    let view: UIView
    func makeUIView(context: Context) -> UIView { view }
    func updateUIView(_ uiView: UIView, context: Context) {}
}

/// 自建多页正文，不依赖真实书籍、站点或用户文件。
private actor AutoReadFixtureBuilder: AttributedStringBuilding {
    nonisolated var chapterCount: Int { 1 }
    nonisolated var prefersLazyByteScan: Bool { true }
    private let text = String(repeating: "自动阅读回归使用合成正文，确认每一页均有内容。\n", count: 300)
    nonisolated func chapterTitle(at index: Int) -> String { "合成章节" }
    func chapterDataSize(at index: Int) -> Int { text.utf8.count }
    nonisolated func buildChapter(at index: Int, settings: ReaderRenderSettings,
                                 themeTextColor: UIColor, themeBackgroundColor: UIColor) async throws -> AttributedChapterBuildResult {
        AttributedChapterBuildResult(attributedString: NSAttributedString(string: text, attributes: [
            .font: UIFont.systemFont(ofSize: settings.fontSize), .foregroundColor: themeTextColor,
            .backgroundColor: themeBackgroundColor
        ]), imagePage: nil, pageBackgroundImage: nil, anchorOffsets: [:])
    }
}
