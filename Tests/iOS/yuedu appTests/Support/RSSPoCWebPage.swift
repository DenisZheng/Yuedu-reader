import UIKit
import WebKit
import XCTest

/// 为WebKit资源/媒体实验提供真实可见窗口；不会替换App已有的根控制器或key window。
@MainActor
final class RSSPoCWebPage {
    let view: WKWebView
    let waiter = RSSPoCNavigationWaiter()
    private let window: UIWindow

    init(configuration: WKWebViewConfiguration) throws {
        view = WKWebView(frame: CGRect(x: 0, y: 0, width: 320, height: 240), configuration: configuration)
        view.navigationDelegate = waiter
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        window = UIWindow(windowScene: scene)
        let controller = UIViewController()
        window.rootViewController = controller
        controller.view.addSubview(view)
        window.isHidden = false
    }

    func close() {
        view.stopLoading()
        view.navigationDelegate = nil
        view.removeFromSuperview()
        window.isHidden = true
    }
}
