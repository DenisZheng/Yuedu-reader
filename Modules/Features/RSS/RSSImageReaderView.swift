import SwiftUI
import UIKit

/// RSS图片只保存阅读UI状态；请求/解码由共享服务处理，不伪装成书籍或创建另一份图片缓存。
struct RSSImageReaderView: View {
    let source: RSSSource
    let rawURL: String
    let baseURL: URL?
    let context: RSSOpenTarget.RequestContext?
    let owner: RSSStore?
    var ruleURL = false
    @State private var model = RSSImageReaderModel()
    @State private var retryID = UUID()
    @State private var zoom: RSSImageZoomCommand?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if let image = model.image {
                RSSZoomableImage(image: image, command: zoom, animated: !reduceMotion)
                    .accessibilityIdentifier("rss.image.content")
            } else if let error = model.error {
                ContentUnavailableView {
                    Label(localized("載入失敗"), systemImage: "photo")
                } description: { Text(error) }
                actions: { Button(localized("重試")) { retryID = UUID() }.accessibilityIdentifier("rss.image.retry") }
            } else if model.isLoading { ProgressView().accessibilityLabel(localized("載入中")) }
            else { ContentUnavailableView(localized("圖片"), systemImage: "photo") }
        }
        .background(DSColor.background)
        .navigationTitle(localized("圖片"))
        .toolbarTitleDisplayMode(.inline)
        .hidesRootTabBar()
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button { zoom = .init(direction: .out) } label: { Label(localized("縮小"), systemImage: "minus.magnifyingglass").labelStyle(.iconOnly) }
                    .disabled(model.image == nil)
                Button { zoom = .init(direction: .in) } label: { Label(localized("放大"), systemImage: "plus.magnifyingglass").labelStyle(.iconOnly) }
                    .disabled(model.image == nil)
            }
        }
        .task(id: retryID) { await model.load(rawURL, source: source, base: baseURL, context: context, owner: owner, ruleURL: ruleURL) }
        .onDisappear { model.releaseAccess() }
    }
}

@MainActor @Observable final class RSSImageReaderModel {
    private(set) var image: UIImage?
    private(set) var isLoading = false
    private(set) var error: String?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var state: RSSRuntimeState?
    @ObservationIgnored private var token: UUID?
    @ObservationIgnored private var observer: NSObjectProtocol?

    func load(_ raw: String, source: RSSSource, base: URL?, context: RSSOpenTarget.RequestContext?, owner: RSSStore?, ruleURL: Bool) async {
        releaseAccess()
        let id = generation
        isLoading = true; error = nil; image = nil
        defer { if id == generation { isLoading = false } }
        do {
            let runtime = try await RSSRuntime.make(source: source, owner: owner)
            try Task.checkCancellation()
            guard id == generation else { return }
            state = runtime.state
            token = runtime.state.addCancellation { [weak self] in Task { @MainActor in self?.revoke(id) } }
            let key = RSSRuntime.authenticationKey(for: source)
            observer = NotificationCenter.default.addObserver(forName: .bookSourceLoginInfoDidChange, object: nil, queue: nil) { [weak self] note in
                guard note.userInfo?["sourceURL"] as? String == key else { return }
                Task { @MainActor [weak self] in if self?.state?.isCurrent == false { self?.revoke(id) } }
            }
            let result = try await RSSImageService.load(raw, source: source, baseURL: base, context: context, owner: owner, ruleURL: ruleURL)
            let value = try await RSSImageService.displayImage(result.data)
            try Task.checkCancellation()
            guard id == generation, runtime.state.isCurrent else { throw CancellationError() }
            image = value
        } catch is CancellationError { if id == generation, !Task.isCancelled { revoke(id) } }
        catch { if id == generation { self.error = (error as? RSSWebFailure)?.localizedDescription ?? RSSWebFailure.resourceUnavailable.localizedDescription } }
    }
    func releaseAccess() {
        generation &+= 1
        if let token { state?.removeCancellation(token) }
        if let observer { NotificationCenter.default.removeObserver(observer) }
        token = nil; observer = nil; state = nil
        image = nil; isLoading = false
    }
    private func revoke(_ id: Int) {
        guard id == generation else { return }
        image = nil; isLoading = false
        error = localized("訂閱來源或登入狀態已變更，請重新開啟")
        releaseAccess()
    }
}

private struct RSSImageZoomCommand {
    enum Direction { case `in`, out }
    let id = UUID()
    var direction: Direction
}

/// 复用固定页阅读器的pinch/双击行为，布局只在UIKit真实尺寸变化时调整，不把每帧缩放发布给SwiftUI。
private struct RSSZoomableImage: UIViewRepresentable {
    var image: UIImage
    var command: RSSImageZoomCommand?
    var animated: Bool
    func makeUIView(context: Context) -> Container { Container() }
    func updateUIView(_ view: Container, context: Context) {
        view.setImage(image)
        if let command, view.handled != command.id {
            view.handled = command.id
            let scale = view.scroll.zoomScale * (command.direction == .in ? FixedPageZoom.doubleTapScale : 1 / FixedPageZoom.doubleTapScale)
            view.scroll.setZoomScale(min(view.scroll.maximumZoomScale, max(view.scroll.minimumZoomScale, scale)), animated: animated)
        }
    }
    final class Container: UIView {
        let scroll = FixedPageZoomableScrollView()
        let picture = UIImageView()
        var handled: UUID?
        private var fitted: CGSize = .zero
        override init(frame: CGRect) {
            super.init(frame: frame)
            addSubview(scroll); scroll.zoomView = picture
            picture.isAccessibilityElement = true
            picture.accessibilityLabel = localized("圖片")
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        func setImage(_ value: UIImage) {
            guard picture.image !== value else { return }
            picture.image = value; fitted = .zero; setNeedsLayout()
        }
        override func layoutSubviews() {
            super.layoutSubviews()
            scroll.frame = bounds
            guard fitted != bounds.size, bounds.width > 0, bounds.height > 0, let image = picture.image,
                  image.size.width > 0, image.size.height > 0 else { return }
            fitted = bounds.size
            scroll.resetZoom()
            let scale = min(bounds.width / image.size.width, bounds.height / image.size.height)
            picture.frame = CGRect(origin: .zero, size: CGSize(width: image.size.width * scale, height: image.size.height * scale))
            scroll.contentSize = picture.bounds.size
        }
    }
}

#Preview("RSS image error") {
    NavigationStack {
        RSSImageReaderView(source: RSSSource(name: "Preview", url: "https://example.invalid"), rawURL: "not-an-image", baseURL: nil,
                           context: nil, owner: nil)
    }
}
