import SwiftUI
import UIKit
import XCTest
@testable import yuedu_app

/// 改编自上游a4df38b6：真实BookRow与List原生滑动动作组合后的可访问性元素。
/// 不读写真实书架；与主界面一致提供删除／置顶滑动动作，检查每种动作只出现一次。
@MainActor
final class BookshelfRowVoiceOverActionsTests: XCTestCase {
    func testUnpinnedBookOffersEachActionOnce() async throws {
        try await verifyActions(isPinned: false)
    }

    func testPinnedBookOffersEachActionOnce() async throws {
        try await verifyActions(isPinned: true)
    }

    private func verifyActions(isPinned: Bool) async throws {
        let accessibility = try XCTUnwrap(dlopen("/usr/lib/libAccessibility.dylib", RTLD_NOW))
        typealias GetFlag = @convention(c) () -> Bool
        typealias SetFlag = @convention(c) (Bool) -> Void
        let enabled = unsafeBitCast(try XCTUnwrap(dlsym(accessibility, "_AXSAutomationEnabled")), to: GetFlag.self)
        let setEnabled = unsafeBitCast(try XCTUnwrap(dlsym(accessibility, "_AXSSetAutomationEnabled")), to: SetFlag.self)
        let previous = enabled()
        setEnabled(true)
        defer { setEnabled(previous); dlclose(accessibility) }

        var book = ReadingBook(title: "转子动作测试书", author: "测试作者", contentFilename: "")
        book.pinnedAt = isPinned ? Date(timeIntervalSinceReferenceDate: 1) : nil
        let pin = BookshelfPinLabel.title(isPinned: isPinned)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousWindow = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: List {
            BookRow(book: book, onTap: { _ in }, onEdit: {}, onDelete: {}, onShowWork: {}, onTogglePin: {})
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button(role: .destructive) {} label: { Label(localized("刪除"), systemImage: "trash") }
                    Button {} label: { Label(pin, systemImage: "pin") }
                }
        })
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previousWindow?.makeKeyAndVisible()
        }
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            self.row(in: window, title: book.title) != nil
        }, object: nil)
        await fulfillment(of: [ready], timeout: 5)
        let row = try XCTUnwrap(row(in: window, title: book.title))
        let actions = (row.accessibilityCustomActions ?? []).map(\.name)
        XCTAssertEqual(actions.filter { $0 == pin }.count, 1, "\(actions)")
        XCTAssertEqual(actions.filter { [localized("刪除"), localized("刪除書籍")].contains($0) }.count, 1, "\(actions)")
        XCTAssertEqual(actions.filter { $0 == localized("編輯書籍資訊") }.count, 1, "\(actions)")
        XCTAssertEqual(actions.filter { $0 == localized("作品詳情") }.count, 1, "\(actions)")
    }

    private func row(in object: NSObject, title: String) -> NSObject? {
        if object.isAccessibilityElement {
            return (object.accessibilityLabel ?? "").hasPrefix(title) ? object : nil
        }
        if let children = object.accessibilityElements as? [NSObject] {
            return children.lazy.compactMap { self.row(in: $0, title: title) }.first
        }
        return (object as? UIView)?.subviews.lazy.compactMap { self.row(in: $0, title: title) }.first
    }
}
