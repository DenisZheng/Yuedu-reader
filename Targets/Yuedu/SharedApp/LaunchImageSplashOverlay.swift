import SwiftUI

/// 自定义启动图只由用户开关和图片决定，不等待账号或会员状态。
struct LaunchImageSplashOverlay: View {
    @Bindable private var settings = GlobalSettings.shared
    @Environment(\.colorScheme) private var colorScheme
    @State private var visible = true
    @State private var image: UIImage?

    private static var hasPlayed = false
    /// 设计指定的展示时长，不用于等待状态稳定。
    private let holdDuration: UInt64 = 1_300_000_000

    var body: some View {
        ZStack {
            if visible, let image {
                GeometryReader { proxy in
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .clipped()
                        .background(colorScheme == .dark ? Color.black : Color.white)
                }
                .ignoresSafeArea()
                .transition(.opacity)
            }
        }
        .animation(DSAnimation.splashFade, value: visible)
        .task {
            guard !Self.hasPlayed else { visible = false; return }
            Self.hasPlayed = true
            guard settings.launchImageEnabled,
                  let url = settings.launchImageURL(for: colorScheme) else {
                visible = false
                return
            }
            let loaded = await Task.detached(priority: .userInitiated) {
                SourcePerfTrace.span("launch.image.load", thresholdMs: 5) {
                    UIImage(contentsOfFile: url.path)
                }
            }.value
            guard !Task.isCancelled else { return }
            guard let loaded else {
                AppLogger.cache("Launch image could not be loaded", level: .warning)
                visible = false
                return
            }
            image = loaded
            do {
                try await Task.sleep(nanoseconds: holdDuration)
            } catch is CancellationError {
                return
            } catch {
                AppLogger.error("Launch image display interval failed", error: error)
            }
            visible = false
        }
    }
}

#Preview {
    LaunchImageSplashOverlay()
}
