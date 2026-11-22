import SwiftUI
import UIKit
import XCTest
@testable import yuedu_app

/// 通过已挂载的真实登录 View 执行自建离线脚本，不改共享书架、书源或 Cookie。
@MainActor
final class LoginMenuExecutionTests: XCTestCase {
    @MainActor
    private struct MountedForm {
        let view: BookSourceFormLoginView
        let window: UIWindow
        let previousWindow: UIWindow?

        func close() {
            window.isHidden = true
            window.rootViewController = nil
            previousWindow?.makeKeyAndVisible()
        }
    }

    private func source(traced: Bool) -> BookSource {
        BookSource(
            bookSourceUrl: "https://login-menu-" + UUID().uuidString.lowercased() + ".invalid",
            bookSourceName: traced ? "书山聚合 · 隔离回归" : "隔离菜单"
        )
    }

    private func mount(_ source: BookSource) async throws -> MountedForm {
        let ready = expectation(description: "真实登录状态已安装")
        var installed: BookSourceFormLoginView?
        var view = BookSourceFormLoginView(source: source, onDismiss: {})
        view.onFormReady = { form in
            installed = form
            ready.fulfill()
        }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousWindow = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: view)
        window.makeKeyAndVisible()
        await fulfillment(of: [ready], timeout: 5)
        return MountedForm(view: try XCTUnwrap(installed), window: window, previousWindow: previousWindow)
    }

    func testKeepsOriginalMenuError() async throws {
        let form = try await mount(source(traced: true))
        defer { form.close() }
        let report = await form.view.runButtonJS(
            action: "throw new Error('isolated menu failure');", credentials: [:]
        ).value
        let error = try XCTUnwrap(report)
        XCTAssertEqual(error.title, localized("來源配置腳本錯誤"))
        XCTAssertTrue(error.detail.contains("isolated menu failure"))
    }

    func testOrdinaryErrorAndSuccessfulAction() async throws {
        let form = try await mount(source(traced: false))
        defer { form.close() }
        let failed = await form.view.runButtonJS(
            action: "throw new Error('ordinary menu failure');", credentials: [:]
        ).value
        XCTAssertTrue(failed?.detail.contains("ordinary menu failure") == true)
        let succeeded = await form.view.runButtonJS(action: "40 + 2;", credentials: [:]).value
        XCTAssertNil(succeeded)
    }

    func testQueuedActionUsesSourceAtTap() async throws {
        let original = source(traced: false)
        let form = try await mount(original)
        defer { form.close() }
        let entered = AsyncStream<Void>.makeStream()
        let release = DispatchSemaphore(value: 0)
        defer { release.signal(); entered.continuation.finish() }
        // 只阻塞专用脚本线程，主线程按开始事件继续；不靠延时制造竞态。
        let gate = Task {
            await SourceScriptThread.run {
                entered.continuation.yield(())
                release.wait()
            }
        }
        var iterator = entered.stream.makeAsyncIterator()
        _ = await iterator.next()
        let action = form.view.runButtonJS(action: "throw new Error(source.getTag());", credentials: [:])
        var updated = original
        updated.bookSourceName = "更新后的隔离菜单"
        form.view.adoptLatest(updated)
        release.signal()
        await gate.value
        let result = await action.value
        let report = try XCTUnwrap(result)
        XCTAssertTrue(report.detail.contains(original.bookSourceName))
        XCTAssertFalse(report.detail.contains(updated.bookSourceName))
    }
}
