import SwiftUI
import UIKit

/// UIKit 只拥有封面阅读器的 push/pop；嵌入的 SwiftUI 栈拥有书架内页和搜索路径。
/// 不能把 UIKit 阅读器直接追加到 SwiftUI 的值路径栈，否则状态刷新会移除它。
struct BookshelfNavigationHost<Content: View>: UIViewControllerRepresentable {
    let navigator: ReaderNavigationCoordinator
    @ViewBuilder var content: Content

    func makeCoordinator() -> Coordinator { Coordinator(navigator: navigator) }

    func makeUIViewController(context: Context) -> UINavigationController {
        let hosting = UIHostingController(rootView: AnyView(content.environment(\.self, context.environment)))
        let root = UIViewController()
        root.addChild(hosting)
        root.view.addSubview(hosting.view)
        hosting.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            hosting.view.leadingAnchor.constraint(equalTo: root.view.leadingAnchor),
            hosting.view.trailingAnchor.constraint(equalTo: root.view.trailingAnchor),
            hosting.view.topAnchor.constraint(equalTo: root.view.topAnchor),
            hosting.view.bottomAnchor.constraint(equalTo: root.view.bottomAnchor),
        ])
        hosting.didMove(toParent: root)
        context.coordinator.hosting = hosting
        let navigation = UINavigationController(rootViewController: root)
        navigation.setNavigationBarHidden(true, animated: false)
        navigator.attach(to: navigation, owner: context.coordinator.owner)
        return navigation
    }

    func updateUIViewController(_ navigation: UINavigationController, context: Context) {
        context.coordinator.hosting?.rootView = AnyView(content.environment(\.self, context.environment))
    }

    static func dismantleUIViewController(_ navigation: UINavigationController, coordinator: Coordinator) {
        // 沿既有 owner-scoped 延后拆卸，避免 SwiftUI 更新图时同步发布阅读器状态。
        coordinator.navigator.detachNavigationController(afterDismantling: coordinator.owner)
    }

    @MainActor
    final class Coordinator {
        let owner = UUID()
        let navigator: ReaderNavigationCoordinator
        weak var hosting: UIHostingController<AnyView>?

        init(navigator: ReaderNavigationCoordinator) { self.navigator = navigator }
    }
}

#Preview("书架导航容器") {
    BookshelfNavigationHost(navigator: ReaderNavigationCoordinator()) {
        NavigationStack { Text(localized("書架")) }
    }
}
