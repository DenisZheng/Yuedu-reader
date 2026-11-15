import Nuke
import Testing
import UIKit
@testable import yuedu_app

/// 自建长图通过生产图片缓存、页面和跨页缩放容器；不读取用户漫画或修改阅读模式。
@Suite("Fixed page long images", .serialized)
@MainActor
struct FixedPageLongImageTests {
    @Test("长图在翻页模式按页宽显示，底部可以滚动到达")
    func longImageIsWidthFittedAndScrollable() throws {
        let spread = makeSpread(size: CGSize(width: 400, height: 4000))
        let page = try #require(spread.pageControllers.first)
        let scroll = try #require(spread.view.subviews.compactMap { $0 as? UIScrollView }.first)
        #expect(abs(page.imageView.frame.width - 400) < 0.5)
        #expect(abs(page.imageView.frame.height - 4000) < 0.5)
        #expect(abs(scroll.contentSize.height - 4000) < 0.5)
        scroll.setContentOffset(CGPoint(x: 0, y: 3200), animated: false)
        #expect(abs(scroll.contentOffset.y - 3200) < 0.5)
        #expect(page.imageView.convert(page.imageView.bounds, to: spread.view).maxY <= 800.5)
    }

    @Test("关闭缩放不应关闭长图滚动")
    func longImageScrollsWithoutZoom() throws {
        var configuration = FixedPageReaderConfiguration.recommendedDefault(for: .ltr)
        configuration.isZoomEnabled = false
        let spread = makeSpread(size: CGSize(width: 400, height: 4000), configuration: configuration)
        let scroll = try #require(spread.view.subviews.compactMap { $0 as? UIScrollView }.first)
        #expect(scroll.isScrollEnabled)
        #expect(scroll.maximumZoomScale == scroll.minimumZoomScale)
        #expect(scroll.contentSize.height > scroll.bounds.height)
    }

    @Test("翻回长图保留未缩放时的滚动位置")
    func longImageRestoresScrollPosition() throws {
        let spread = makeSpread(size: CGSize(width: 400, height: 4000))
        let scroll = try #require(spread.view.subviews.compactMap { $0 as? UIScrollView }.first)
        scroll.contentOffset = CGPoint(x: 0, y: 1700)
        let position = try #require(spread.currentZoom)
        #expect(position.scale == 1)
        let restored = makeSpread(size: CGSize(width: 400, height: 4000), restored: position)
        let restoredScroll = try #require(restored.view.subviews.compactMap { $0 as? UIScrollView }.first)
        #expect(abs(restoredScroll.contentOffset.y - 1700) < 0.5)
    }

    @Test("未缓存的长图加载后也扩展布局，缩放不会再次压成一屏")
    func freshlyLoadedLongImageRetainsHeight() async throws {
        let url = URL.temporaryDirectory.appendingPathComponent("FixedPageLongImageTests-load-\(UUID().uuidString).png")
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let data = UIGraphicsImageRenderer(size: CGSize(width: 400, height: 4000), format: format).pngData { context in
            UIColor.systemTeal.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 400, height: 4000))
        }
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let page = FixedPage(id: 0, imageURL: url.absoluteString, headers: [:], localURL: url)
        let spread = FixedPageSpreadViewController(spreadIndex: 0, pages: [page],
            fixedPageReaderConfiguration: .recommendedDefault(for: .ltr), targetWidth: 400)
        spread.view.frame = CGRect(x: 0, y: 0, width: 400, height: 800)
        spread.view.layoutIfNeeded()
        await spread.pageControllers.first?.loadTask?.value
        spread.view.layoutIfNeeded()
        let controller = try #require(spread.pageControllers.first)
        let scroll = try #require(spread.view.subviews.compactMap { $0 as? UIScrollView }.first)
        #expect(abs(controller.imageView.frame.height - 4000) < 0.5)
        #expect(abs(scroll.contentSize.height - 4000) < 0.5)
        scroll.setZoomScale(2, animated: false)
        spread.view.setNeedsLayout()
        spread.view.layoutIfNeeded()
        #expect(abs(scroll.contentSize.height - 8000) < 0.5)
        #expect(abs(controller.imageView.frame.width - 400) < 0.5)
    }

    @Test("双页长图旁的加载和重试控件仍在屏幕中央")
    func neighboringPageControlsStayInViewport() async throws {
        let long = makeSpread(size: CGSize(width: 400, height: 4000))
        let url = URL.temporaryDirectory.appendingPathComponent("FixedPageLongImageTests-missing-\(UUID().uuidString).png")
        let missing = FixedPage(id: 1, imageURL: url.absoluteString, headers: [:], localURL: url)
        var configuration = FixedPageReaderConfiguration.recommendedDefault(for: .ltr)
        configuration.pageSpreadLayout = .double
        let spread = FixedPageSpreadViewController(spreadIndex: 0, pages: [long.pages[0], missing],
            fixedPageReaderConfiguration: configuration, targetWidth: 800)
        spread.view.frame = CGRect(x: 0, y: 0, width: 800, height: 800)
        spread.view.layoutIfNeeded()
        let neighbor = try #require(spread.pageControllers.last)
        await neighbor.loadTask?.value
        spread.view.layoutIfNeeded()
        let spinner = try #require(neighbor.view.subviews.compactMap { $0 as? UIActivityIndicatorView }.first)
        let retry = try #require(neighbor.view.subviews.compactMap { $0 as? UIButton }.first)
        #expect(abs(spinner.frame.midY - 400) < 0.5)
        #expect(abs(retry.frame.midY - 400) < 0.5)
        #expect(!retry.isHidden)
    }

    @Test("普通漫画页继续整页居中，不改变用户选择的模式")
    func ordinaryPageStillFits() throws {
        let spread = makeSpread(size: CGSize(width: 400, height: 600))
        let page = try #require(spread.pageControllers.first)
        let scroll = try #require(spread.view.subviews.compactMap { $0 as? UIScrollView }.first)
        #expect(page.imageView.frame == CGRect(x: 0, y: 100, width: 400, height: 600))
        #expect(scroll.contentSize == CGSize(width: 400, height: 800))
        #expect(spread.fixedPageReaderConfiguration.mode == .ltr)
    }

    private func makeSpread(
        size: CGSize,
        configuration: FixedPageReaderConfiguration = .recommendedDefault(for: .ltr),
        restored: FixedPageSpreadViewController.Zoom? = nil
    ) -> FixedPageSpreadViewController {
        let url = URL.temporaryDirectory.appendingPathComponent("FixedPageLongImageTests-\(UUID().uuidString).png")
        let page = FixedPage(id: 0, imageURL: url.absoluteString, headers: [:], localURL: url)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.systemTeal.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
        let request = FixedPageImageLoader.request(for: page, targetWidth: 400, cropBorders: configuration.cropBorders)
        ImagePipeline.shared.cache[request] = ImageContainer(image: image)
        let spread = FixedPageSpreadViewController(spreadIndex: 0, pages: [page],
            fixedPageReaderConfiguration: configuration, targetWidth: 400)
        spread.restoredZoom = restored
        spread.view.frame = CGRect(x: 0, y: 0, width: 400, height: 800)
        spread.view.layoutIfNeeded()
        return spread
    }
}
