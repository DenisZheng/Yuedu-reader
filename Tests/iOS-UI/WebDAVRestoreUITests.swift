import XCTest

/// 仅终止本测试启动的隔离App，合成目录在测试结束后清理，不触碰用户/模拟器既有数据。
final class WebDAVRestoreUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor func testTerminationAfterFileWriteRecoversBeforeStoreLoads() throws {
        try terminateAndRelaunch(after: "bookSources")
    }

    @MainActor func testTerminationAfterRSSWriteRecoversPrivateLocalState() throws {
        try terminateAndRelaunch(after: "rss")
    }

    @MainActor
    func testCorruptJournalBlocksStoresAndAllowsSafeRetryAtAX5() throws {
        let root = URL.temporaryDirectory.appendingPathComponent("WebDAVRestoreUITests-" + UUID().uuidString)
        let journal = root.appendingPathComponent("journal")
        try FileManager.default.createDirectory(at: journal, withIntermediateDirectories: true)
        defer { do { try FileManager.default.removeItem(at: root) } catch { XCTFail("清理隔离fixture失败") } }
        let marker = journal.appendingPathComponent("active.json")
        try Data("broken".utf8).write(to: marker)
        let app = XCUIApplication()
        app.launchArguments = ["-rss-poc-isolated-host", "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
            "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL", "-AppleInterfaceStyle", "Dark"]
        app.launchEnvironment["WEBDAV_RESTORE_FIXTURE"] = root.path
        app.launch()
        defer { app.terminate() }
        let retry = app.buttons["webdav.recovery.retry"]
        XCTAssertTrue(retry.waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertTrue(retry.isHittable)
        XCTAssertFalse(app.staticTexts["webdav.fixture.state"].exists)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("seeded").path), "失败时不能初始化业务owner")
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "recovery-error-dark-ax5"; screenshot.lifetime = .keepAlways; add(screenshot)
        // 仅在本测试目录修正损坏日志，再验证原生重试；不把重试当作原失败已通过。
        try FileManager.default.removeItem(at: marker)
        retry.tap()
        XCTAssertTrue(app.staticTexts["Original data has been recovered. Close and reopen the app."].waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertFalse(app.staticTexts["webdav.fixture.state"].exists)
        app.terminate(); app.launch()
        let state = app.staticTexts["webdav.fixture.state"]
        XCTAssertTrue(state.waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertEqual(state.label, "ready-original")
    }

    @MainActor
    private func terminateAndRelaunch(after boundary: String) throws {
        let root = URL.temporaryDirectory.appendingPathComponent("WebDAVRestoreUITests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { do { try FileManager.default.removeItem(at: root) } catch { XCTFail("清理隔离fixture失败") } }
        let app = XCUIApplication()
        app.launchArguments = ["-rss-poc-isolated-host", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launchEnvironment["WEBDAV_RESTORE_FIXTURE"] = root.path
        app.launchEnvironment["WEBDAV_RESTORE_BOUNDARY"] = boundary
        app.launch()
        defer { app.terminate() }
        let state = app.staticTexts["webdav.fixture.state"]
        XCTAssertTrue(state.waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertEqual(state.label, "ready-original")
        app.buttons["webdav.fixture.restore"].tap()
        let paused = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == 'paused'"), object: state)
        XCTAssertEqual(XCTWaiter.wait(for: [paused], timeout: 10), .completed, app.debugDescription)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("journal/active.json").path))
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("book_sources.json")), Data("[]".utf8))
        app.terminate()
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("journal/active.json").path),
            "进程退出后恢复日志仍应存在，验证的是重启回滚而非取消回滚")
        app.launch()
        XCTAssertTrue(state.waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertEqual(state.label, "ready-original", "启动恢复必须早于RSSStore初始化，包含原正文与私有变量")
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("book_sources.json")), Data(" [ ]\n".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("journal/active.json").path))
    }
}
