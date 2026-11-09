import SwiftUI
import Testing
import UIKit
@testable import yuedu_app

/// S6新增页面在深色、最大辅助字号下的可读性与VoiceOver元素：
/// 断言错误/重试控件可被读出且未被截断到不可见，并输出截图供人工检查（YUEDU_VISUAL_DIR）。
@Suite("RSS S6 visual and accessibility", .serialized)
@MainActor struct RSSS6VisualAccessibilityTests {
    @Test("错误态（类型化文章/图片/动作错误/SVG受限）在深色+AX5下可读出标题、说明与重试按钮")
    func errorStates() async throws {
        let directory = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let owner = RSSStore(storageDirectory: directory)
        defer { if FileManager.default.fileExists(atPath: directory.path) {
            do { try FileManager.default.removeItem(at: directory) } catch { Issue.record(error) } } }
        var source = RSSSource(name: "Visual", url: "https://visual-fixture.invalid")
        source.importedFromLegado = true; source.contentType = .video
        owner.addSource(source)
        var item = RSSItem(id: "visual", title: "Visual", link: "", sourceId: source.id)
        item.contentType = .video
        owner.mergeFetchedItems([item], for: source.id)
        let article = try #require(owner.article(id: item.id))
        let router = RSSWebActionRouter()
        router.error = RSSWebFailure.imageFormatRestricted.localizedDescription
        let screens: [(String, AnyView, [String])] = [
            ("typed-error", AnyView(RSSTypedArticleView(article: article, source: source, owner: owner)),
             [localized("載入失敗"), localized("重試")]),
            ("image-error", AnyView(RSSImageReaderView(source: source, rawURL: "javascript:void(0)", baseURL: nil, context: nil, owner: owner)),
             [localized("載入失敗"), localized("重試")]),
            ("action-error", AnyView(Text("Page").frame(maxWidth: .infinity, maxHeight: .infinity).modifier(RSSWebActionPresentation(router: router, owner: owner))),
             [RSSWebFailure.imageFormatRestricted.localizedDescription, localized("關閉")])
        ]
        try await withAutomation {
            for (name, view, expected) in screens {
                for scheme in [ColorScheme.dark, .light] {
                    let window = try host(NavigationStack { view }
                        .environment(\.dynamicTypeSize, .accessibility5)
                        .environment(\.colorScheme, scheme)
                        .environmentObject(BookStore(metadataFileURL: directory.appendingPathComponent("books.json"))), dark: scheme == .dark)
                    defer { window.isHidden = true; window.rootViewController = nil }
                    let deadline = ContinuousClock.now + .seconds(6)
                    @MainActor func missing() -> [String] { let found = labels(window); return expected.filter { label in !found.contains { $0.contains(label) } } }
                    while !missing().isEmpty, ContinuousClock.now < deadline { await Task.yield() }
                    #expect(missing().isEmpty, "\(name) \(scheme) 缺少VoiceOver元素：\(missing())，实际：\(labels(window))")
                    let retry = buttons(window).first { ($0.accessibilityLabel ?? "") == expected.last }
                    #expect(retry != nil, "\(name) 的操作必须是可激活按钮")
                    if let retry {
                        let frame = retry.accessibilityFrame
                        #expect(window.bounds.intersects(frame) && frame.height >= 20, "\(name) 按钮在AX5下被挤出屏幕：\(frame)")
                    }
                    snapshot(window, name: "\(name)-\(scheme == .dark ? "dark" : "light")-ax5")
                }
            }
        }
        try await owner.flushPersistence()
    }

    private func host<V: View>(_ view: V, dark: Bool) throws -> UIWindow {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.overrideUserInterfaceStyle = dark ? .dark : .light
        let controller = UIHostingController(rootView: view)
        controller.traitOverrides.preferredContentSizeCategory = .accessibilityExtraExtraExtraLarge
        window.rootViewController = controller
        window.makeKeyAndVisible()
        return window
    }
    private func snapshot(_ window: UIWindow, name: String) {
        guard let folder = ProcessInfo.processInfo.environment["YUEDU_VISUAL_DIR"] else { return }
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
        do { try image.pngData()?.write(to: URL(fileURLWithPath: folder).appendingPathComponent(name + ".png")) }
        catch { Issue.record(error) }
    }
    private func elements(_ root: Any, depth: Int = 0) -> [NSObject] {
        guard depth < 40, let object = root as? NSObject else { return [] }
        var result = [object]
        if let view = root as? UIView { for sub in view.subviews { result += elements(sub, depth: depth + 1) } }
        if let children = object.accessibilityElements { for child in children { result += elements(child, depth: depth + 1) } }
        return result
    }
    private func labels(_ window: UIWindow) -> [String] { elements(window).compactMap { $0.accessibilityLabel }.filter { !$0.isEmpty } }
    private func buttons(_ window: UIWindow) -> [NSObject] { elements(window).filter { $0.accessibilityTraits.contains(.button) } }
    private func withAutomation(_ body: () async throws -> Void) async throws {
        let accessibility = try #require(dlopen("/usr/lib/libAccessibility.dylib", RTLD_NOW))
        typealias GetFlag = @convention(c) () -> Bool
        typealias SetFlag = @convention(c) (Bool) -> Void
        let enabled = unsafeBitCast(try #require(dlsym(accessibility, "_AXSAutomationEnabled")), to: GetFlag.self)
        let setEnabled = unsafeBitCast(try #require(dlsym(accessibility, "_AXSSetAutomationEnabled")), to: SetFlag.self)
        let was = enabled()
        setEnabled(true)
        defer { setEnabled(was) }
        try await body()
    }
}
