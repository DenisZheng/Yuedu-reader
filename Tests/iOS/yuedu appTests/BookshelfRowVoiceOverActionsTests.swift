import SwiftUI
import UIKit
import XCTest
@testable import yuedu_app

/// 改编自 eaa3d7b7：只挂载自建 BookRow／BookGridCell，不写书架或布局偏好。
/// 测试 target 内读取无障碍运行时汇总动作；所有开关恢复，不用 sleep 等待布局。
@MainActor
final class BookshelfRowVoiceOverActionsTests: XCTestCase {
    func testUnpinnedBookOffersEachActionOnce() async throws {
        try await verifyActions(isPinned: false, grid: false, voiceOver: true)
    }

    func testPinnedBookOffersEachActionOnce() async throws {
        try await verifyActions(isPinned: true, grid: false, voiceOver: true)
    }

    func testGridOffersPinOnce() async throws {
        try await verifyActions(isPinned: false, grid: true, voiceOver: true)
        try await verifyActions(isPinned: true, grid: true, voiceOver: true)
    }

    func testSwitchControlOffersEachActionOnce() async throws {
        try await verifyActions(isPinned: false, grid: false, voiceOver: false, switchControl: true)
    }

    func testOrdinaryTouchKeepsNativeSwipe() async throws {
        try await verifyActions(isPinned: false, grid: false, voiceOver: false)
    }

    func testEditingGridDoesNotOfferDestructiveActions() async throws {
        try await verifyActions(isPinned: false, grid: true, voiceOver: true, editing: true)
    }

    private func verifyActions(
        isPinned: Bool, grid: Bool, voiceOver: Bool, switchControl: Bool = false, editing: Bool = false
    ) async throws {
        let library = try XCTUnwrap(dlopen("/usr/lib/libAccessibility.dylib", RTLD_NOW))
        typealias GetFlag = @convention(c) () -> Bool
        typealias SetFlag = @convention(c) (Bool) -> Void
        var flags: [(get: GetFlag, set: SetFlag, previous: Bool)] = []
        defer {
            for flag in flags.reversed() { flag.set(flag.previous) }
            dlclose(library)
        }
        for (getter, setter, value) in [
            ("_AXSAutomationEnabled", "_AXSSetAutomationEnabled", true),
            ("_AXSApplicationAccessibilityEnabled", "_AXSApplicationAccessibilitySetEnabled", true),
            ("_AXSVoiceOverTouchEnabled", "_AXSVoiceOverTouchSetEnabled", voiceOver)
        ] {
            let get = unsafeBitCast(try XCTUnwrap(dlsym(library, getter)), to: GetFlag.self)
            let set = unsafeBitCast(try XCTUnwrap(dlsym(library, setter)), to: SetFlag.self)
            flags.append((get, set, get()))
            set(value)
        }

        var book = ReadingBook(title: "转子动作测试书", author: "测试作者", contentFilename: "")
        book.pinnedAt = isPinned ? Date(timeIntervalSinceReferenceDate: 1) : nil
        let pin = BookshelfPinLabel.title(isPinned: isPinned)
        let offersSwipe = BookshelfRowSwipe.isOffered(
            voiceOverEnabled: voiceOver, switchControlEnabled: switchControl
        )
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousWindow = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: Group {
            if grid {
                BookGridCell(
                    book: book, coverDisplaySize: CGSize(width: 110, height: 165), isEditing: editing,
                    onOpen: { _ in }, onEdit: {}, onDelete: {}, onShowWork: {}, onTogglePin: {}
                )
            } else {
                List {
                    BookRow(
                        book: book, onTap: { _ in }, onEdit: {}, onDelete: {}, onShowWork: {},
                        onTogglePin: {}, swipeIsOffered: offersSwipe
                    )
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        if offersSwipe {
                            Button(role: .destructive) {} label: { Label(localized("刪除"), systemImage: "trash") }
                            Button {} label: { Label(pin, systemImage: "pin") }
                        }
                    }
                }
            }
        })
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previousWindow?.makeKeyAndVisible()
        }
        // 只在测试中读取汇总动作；生产代码不调用私有无障碍 API。
        let assembled = NSSelectorFromString("_accessibilityCustomActions")
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            self.row(in: window, title: book.title)?.responds(to: assembled) == true
        }, object: nil)
        await fulfillment(of: [ready], timeout: 5)
        window.layoutIfNeeded()
        let row = try XCTUnwrap(row(in: window, title: book.title))
        let actions = (row.perform(assembled)?.takeUnretainedValue() as? [UIAccessibilityCustomAction] ?? []).map(\.name)
        if editing {
            XCTAssertFalse(actions.contains(pin))
            XCTAssertFalse(actions.contains(localized("刪除書籍")))
            return
        }
        if !grid, !voiceOver, !switchControl {
            // 无障碍关闭时只验证触控滑动仍存在，不把运行时转子去重当作普通触控合同。
            XCTAssertTrue(offersSwipe)
            XCTAssertTrue(actions.contains(pin))
            XCTAssertTrue(actions.contains(localized("刪除")))
            XCTAssertFalse(actions.contains(localized("刪除書籍")))
            return
        }
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
