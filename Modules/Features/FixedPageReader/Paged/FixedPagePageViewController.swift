import UIKit
import VisionKit

// MARK: - Page
//
// 单个漫画页：普通页整页适配，长图按页宽展示；加载与重试控件始终位于真实视口内。
// 缩放与长图滚动统一由外层跨页容器提供，页面仅在缩放稳定后按需重新栅格化。

final class FixedPagePageViewController: UIViewController {

    /// Where a two-page spread's spine is, seen from this page. The page sits against it
    /// rather than in the middle of its half, so the two pages meet at the spine.
    enum SpineSide {
        case none
        case left
        case right
    }

    let pageIndex: Int
    private let page: FixedPage
    private let fixedPageReaderConfiguration: FixedPageReaderConfiguration
    private let targetWidth: CGFloat

    var onImageLoaded: ((UIImage) -> Void)?
    var spineSide: SpineSide = .none {
        didSet { if isViewLoaded { layoutImage() } }
    }

    let imageView = UIImageView()
    /// 跨页容器可能高于屏幕，普通页仍按真实视口适配，而非按整条长图的高度放大。
    var viewportSize: CGSize? {
        didSet { if isViewLoaded { layoutImage() } }
    }
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let retryButton = UIButton(type: .system)
    private lazy var spinnerCenterY = spinner.centerYAnchor.constraint(equalTo: view.topAnchor)
    private lazy var retryCenterY = retryButton.centerYAnchor.constraint(equalTo: view.topAnchor)
    private(set) var loadTask: Task<Void, Never>?
    private(set) var refineTask: Task<Void, Never>?
    private var liveTextTask: Task<Void, Never>?
    private var imageAnalysisInteraction: ImageAnalysisInteraction?

    /// Whether Live Text's button shows (`FixedPageZoom.showsLiveTextButton`). Kept so an
    /// analysis that lands later honours it.
    private(set) var showsLiveTextButton = false

    /// The 1x render, kept so zooming back out drops the large one.
    private var baseImage: UIImage?
    /// Width multiple the currently displayed image was rendered at.
    private var renderedWidthMultiple: CGFloat = 1

    init(
        page: FixedPage,
        index: Int,
        fixedPageReaderConfiguration: FixedPageReaderConfiguration,
        targetWidth: CGFloat
    ) {
        self.page = page
        self.pageIndex = index
        self.fixedPageReaderConfiguration = fixedPageReaderConfiguration
        self.targetWidth = targetWidth
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear

        imageView.contentMode = .scaleAspectFit
        view.addSubview(imageView)

        // Live Text (VisionKit) support
        if fixedPageReaderConfiguration.isLiveTextEnabled, ImageAnalyzer.isSupported {
            let interaction = ImageAnalysisInteraction()
            interaction.preferredInteractionTypes = .automatic
            interaction.isSupplementaryInterfaceHidden = !showsLiveTextButton
            imageView.addInteraction(interaction)
            self.imageAnalysisInteraction = interaction
        }

        spinner.color = .white
        spinner.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(spinner)

        retryButton.setTitle(localized("載入失敗，點擊重試"), for: .normal)
        retryButton.setTitleColor(.white, for: .normal)
        retryButton.titleLabel?.font = .systemFont(ofSize: 15, weight: .medium)
        retryButton.translatesAutoresizingMaskIntoConstraints = false
        retryButton.isHidden = true
        retryButton.addTarget(self, action: #selector(retry), for: .touchUpInside)
        view.addSubview(retryButton)

        NSLayoutConstraint.activate([
            spinner.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            spinnerCenterY,
            retryButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            retryCenterY,
        ])

        // A page drawn on demand is a bitmap at the display scale it was loaded for; on a
        // screen of another scale it is drawn again.
        registerForTraitChanges([UITraitDisplayScale.self]) { (self: Self, _) in
            guard self.page.renderSource.isRasterizedOnDemand else { return }
            self.load()
        }

        load()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        layoutImage()
    }

    /// 图片高宽比达到 3:1 才按长图处理；普通漫画页、PDF 和固定版面 EPUB 保持整页适配。
    private var isLongImage: Bool {
        guard !page.renderSource.isRasterizedOnDemand,
              let image = imageView.image, image.size.width > 0 else { return false }
        return image.size.height / image.size.width >= 3
    }

    /// 长图沿用现有跨页容器滚动，不新建嵌套缩放，也不改用户持久化的阅读模式。
    func contentHeight(in viewport: CGSize) -> CGFloat {
        guard isLongImage, let image = imageView.image else { return viewport.height }
        return max(viewport.height, viewport.width * image.size.height / image.size.width)
    }

    private func layoutImage() {
        let bounds = CGRect(origin: .zero, size: viewportSize ?? view.bounds.size)
        // 邻页的长图会撑高整个跨页容器，但加载和重试不能跟着移到屏幕外。
        spinnerCenterY.constant = bounds.height / 2
        retryCenterY.constant = bounds.height / 2
        guard let image = imageView.image, image.size.width > 0, image.size.height > 0 else { return }
        guard bounds.width > 0, bounds.height > 0 else { return }
        let scale = isLongImage
            ? bounds.width / image.size.width
            : min(bounds.width / image.size.width, bounds.height / image.size.height)
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let originX: CGFloat
        switch spineSide {
        case .none: originX = (bounds.width - size.width) / 2
        case .left: originX = 0
        case .right: originX = bounds.width - size.width
        }
        let originY = isLongImage ? 0 : (bounds.height - size.height) / 2
        imageView.frame = CGRect(origin: CGPoint(x: originX, y: originY), size: size)
    }

    private func load() {
        retryButton.isHidden = true
        loadTask?.cancel()
        // A page already in memory goes up as the page is built. Waiting for it left a page
        // turned to empty — the reader's black background — for at least a frame, as in the
        // webtoon (FB-114).
        if let image = FixedPageImageLoader.cachedImage(
            for: page, targetWidth: targetWidth, cropBorders: fixedPageReaderConfiguration.cropBorders
        ) {
            spinner.stopAnimating()
            show(image)
            return
        }
        spinner.startAnimating()
        let renderScale = traitCollection.displayScale
        loadTask = Task { [weak self] in
            guard let self else { return }
            let image = await FixedPageImageLoader.loadImage(
                for: page,
                targetWidth: targetWidth,
                renderScale: renderScale,
                cropBorders: fixedPageReaderConfiguration.cropBorders
            )
            if Task.isCancelled { return }
            self.spinner.stopAnimating()
            if let image {
                self.show(image)
            } else {
                self.retryButton.isHidden = false
            }
        }
    }

    private func show(_ image: UIImage) {
        baseImage = image
        renderedWidthMultiple = 1
        imageView.image = image
        // UI tests find a page only once its image is on screen
        // (DetailReaderBackSwipeUITests). VoiceOver never reads an
        // identifier, and it leaves the image unfocusable as before.
        imageView.accessibilityIdentifier = "fixed_page_image"
        layoutImage()
        onImageLoaded?(image)
        analyzeLiveText(for: image)
    }

    private func analyzeLiveText(for image: UIImage) {
        guard fixedPageReaderConfiguration.isLiveTextEnabled, ImageAnalyzer.isSupported else { return }
        liveTextTask?.cancel()
        liveTextTask = Task { [weak self] in
            let analyzer = ImageAnalyzer()
            let config = ImageAnalyzer.Configuration([.text])
            do {
                let analysis = try await analyzer.analyze(image, configuration: config)
                if Task.isCancelled { return }
                await MainActor.run {
                    guard let self, let interaction = self.imageAnalysisInteraction else { return }
                    interaction.analysis = analysis
                    interaction.setLiveTextButtonHidden(!self.showsLiveTextButton)
                }
            } catch {
                // Ignore background analysis failures
            }
        }
    }

    /// Re-rasterize a vector-backed page (PDF, fixed-layout EPUB) for the spread's zoom
    /// scale, and go back to the 1x render once zoomed out. An image page has no detail
    /// beyond its own pixels, so it stays put.
    func refineImage(forZoomScale zoomScale: CGFloat) {
        guard page.renderSource.isRasterizedOnDemand, targetWidth > 0, baseImage != nil else { return }

        if zoomScale <= 1.05 {
            refineTask?.cancel()
            if renderedWidthMultiple > 1 {
                imageView.image = baseImage
                renderedWidthMultiple = 1
            }
            return
        }

        let renderScale = traitCollection.displayScale
        // No pixel grid yet (a page that has never been in a window): nothing to refine against.
        guard renderScale > 0 else { return }
        let maxPointWidth = FixedPageImageLoader.maxRasterPixelWidth / renderScale
        let desiredWidth = min(targetWidth * zoomScale, maxPointWidth)
        guard desiredWidth > targetWidth * renderedWidthMultiple * 1.2 else { return }

        refineTask?.cancel()
        refineTask = Task { [weak self] in
            guard let self else { return }
            let image = await FixedPageImageLoader.loadImage(
                for: self.page,
                targetWidth: desiredWidth,
                renderScale: renderScale,
                cropBorders: self.fixedPageReaderConfiguration.cropBorders
            )
            if Task.isCancelled { return }
            guard let image else { return }
            self.imageView.image = image
            self.renderedWidthMultiple = desiredWidth / self.targetWidth
        }
    }

    func setShowsLiveTextButton(_ shows: Bool) {
        guard shows != showsLiveTextButton else { return }
        showsLiveTextButton = shows
        imageAnalysisInteraction?.setLiveTextButtonHidden(!shows)
    }

    @objc private func retry() { load() }

    func clearImage() {
        loadTask?.cancel()
        refineTask?.cancel()
        liveTextTask?.cancel()
        imageView.image = nil
        imageView.accessibilityIdentifier = nil
        baseImage = nil
        renderedWidthMultiple = 1
    }
}
