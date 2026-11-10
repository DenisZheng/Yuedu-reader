import SwiftUI
import Testing
import UIKit
@testable import yuedu_app

/// S7 新页面（来源设置、WebDAV 分类备份）在深色+AX5 下 VoiceOver 可读出主要控件且控件在屏幕内。
@Suite("S7 accessibility", .serialized)
@MainActor struct RSSS7AccessibilityTests {
    @Test("来源设置与WebDAV分类备份：开关/按钮可读出并可激活")
    func pagesExposeControls() async throws {
        let directory = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = RSSStore(storageDirectory: directory)
        defer { if FileManager.default.fileExists(atPath: directory.path) {
            do { try FileManager.default.removeItem(at: directory) } catch { Issue.record(error) } } }
        var source = RSSSource(name: "AX", url: "https://ax-fixture.invalid/rss")
        source.ruleArticles = "class.i"; source.importedFromLegado = true; source.loginUrl = "https://ax-fixture.invalid/login"
        let added = try #require(store.addSourcesReturningAdded([source]).first)
        let screens: [(String, AnyView, [String])] = [
            ("source-settings", AnyView(RSSSourceSettingsView(sourceID: added.id, store: store)),
             [localized("啟用"), localized("執行 JavaScript"), localized("規則（Legado JSON）"), localized("登入"), localized("開始除錯")]),
            ("webdav", AnyView(WebDAVSyncView()),
             [localized("書源"), localized("RSS 訂閱"), localized("建立備份版本"), localized("備份歷史與還原")])
        ]
        try await withAutomation {
            for (name, view, expected) in screens {
                let window = try host(NavigationStack { view }.environment(\.colorScheme, .dark))
                defer { window.isHidden = true; window.rootViewController = nil }
                let deadline = ContinuousClock.now + .seconds(6)
                @MainActor func missing() -> [String] { let found = labels(window); return expected.filter { e in !found.contains { $0.contains(e) } } }
                // Form 是懒加载列表：屏外行在 VoiceOver 滚到时才建；逐屏滚动后合并读到的标签。
                var seen = Set<String>()
                @MainActor func collect() { seen.formUnion(labels(window)) }
                @MainActor func missingSeen() -> [String] { expected.filter { e in !seen.contains { $0.contains(e) } } }
                while !missing().isEmpty, ContinuousClock.now < deadline {
                    collect()
                    if missingSeen().isEmpty { break }
                    if let scroll = scrollView(in: window) {
                        let maxY = max(0, scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom)
                        let next = min(maxY, scroll.contentOffset.y + scroll.bounds.height * 0.6)
                        scroll.setContentOffset(CGPoint(x: 0, y: next), animated: false)
                        scroll.layoutIfNeeded()
                    }
                    await Task.yield()
                }
                collect()
                #expect(missingSeen().isEmpty, "\(name) 缺少：\(missingSeen())；实际：\(seen.sorted())")
            }
        }
        try await store.flushPersistence()
    }

    private func scrollView(in root: UIView) -> UIScrollView? {
        if let scroll = root as? UIScrollView, scroll.contentSize.height > scroll.bounds.height { return scroll }
        return root.subviews.lazy.compactMap(scrollView(in:)).first
    }
    private func host<V: View>(_ view: V) throws -> UIWindow {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.overrideUserInterfaceStyle = .dark
        let controller = UIHostingController(rootView: view)
        controller.traitOverrides.preferredContentSizeCategory = .accessibilityExtraExtraExtraLarge
        window.rootViewController = controller
        window.makeKeyAndVisible()
        return window
    }
    private func elements(_ root: Any, depth: Int = 0) -> [NSObject] {
        guard depth < 40, let object = root as? NSObject else { return [] }
        var result = [object]
        if let view = root as? UIView { for sub in view.subviews { result += elements(sub, depth: depth + 1) } }
        if let children = object.accessibilityElements { for child in children { result += elements(child, depth: depth + 1) } }
        return result
    }
    private func labels(_ window: UIWindow) -> [String] { elements(window).compactMap { $0.accessibilityLabel }.filter { !$0.isEmpty } }
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
