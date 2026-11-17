import XCTest

/// 本机独立RSS存储、停用的合成源，不触碰用户源或联网验证。覆盖原生方格/筛选/多选/确认删除。
final class RSSSourceHomeUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    private func fixture() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("RSSSourceHome-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let sources: [[String: Any]] = [
            ["id": "a", "name": "Alpha", "url": "http://127.0.0.1:9/a", "enabled": false, "sourceGroup": "News", "sortOrder": 0],
            ["id": "b", "name": "Beta", "url": "http://127.0.0.1:9/b", "enabled": false, "sourceGroup": "Media", "sortOrder": 1,
             "startHtml": "<html><body>Generated fixture page</body></html>"],
            ["id": "c", "name": "Gamma", "url": "http://127.0.0.1:9/c", "enabled": false, "sortOrder": 2]
        ].map { value in
            value.merging([
                "newArticleNotificationsEnabled": false, "articleStyle": 0, "customOrder": 0,
                "enableJs": true, "enabledCookieJar": false, "lastUpdateTime": 0,
                "loadWithBaseUrl": true, "singleUrl": false
            ]) { original, _ in original }
        }
        try JSONSerialization.data(withJSONObject: sources).write(to: directory.appendingPathComponent("rss_sources.json"))
        try JSONSerialization.data(withJSONObject: [
            ["id": "news", "name": "News", "sortOrder": 0],
            ["id": "media", "name": "Media", "sortOrder": 1]
        ]).write(to: directory.appendingPathComponent("rss_folders.json"))
        return directory
    }

    @MainActor private func launch(_ directory: URL, extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-no-official-modules", "-onboarding.completed", "YES", "-yd_icloud_auto_sync", "NO",
            "-yd_source_disclaimer_accepted", "YES", "-AppleLanguages", "(zh-Hant)", "-AppleLocale", "zh_TW",
            "-rss-store-dir", directory.path, "-rss_main_feed_smart_feeds_expanded", "NO"] + extra
        app.launch()
        return app
    }

    @MainActor private func menu(_ title: String, app: XCUIApplication) {
        app.navigationBars.buttons["更多"].firstMatch.tap()
        let item = app.buttons[title].firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 5), app.debugDescription)
        item.tap()
    }

    @MainActor func testLibraryEntryRemovedAndGridGroupsPersist() throws {
        let directory = try fixture()
        defer { do { try FileManager.default.removeItem(at: directory) } catch { XCTFail("测试目录清理失败") } }
        var app = launch(directory)
        XCTAssertTrue(app.rootTab("資源庫").waitForExistence(timeout: 25))
        app.rootTab("資源庫").tap()
        XCTAssertFalse(app.buttons["library.rss"].exists)
        app.rootTab("訂閱").tap()
        // 从当前保存的布局回到树型，再通过真实菜单切换；launchArguments默认值会压过AppStorage写入。
        app.navigationBars.buttons["更多"].firstMatch.tap()
        XCTAssertTrue(app.buttons["管理訂閱源"].firstMatch.waitForExistence(timeout: 5))
        let tree = app.buttons["樹狀列表"].firstMatch
        if tree.exists { tree.tap() } else {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.5)).tap()
        }
        let a = app.buttons["rss.source.a"].firstMatch
        XCTAssertTrue(a.waitForExistence(timeout: 10), app.debugDescription)
        menu("方格顯示", app: app)
        let picker = app.buttons["rss.sourceGroup"].firstMatch
        XCTAssertTrue(picker.waitForExistence(timeout: 10), app.debugDescription)
        let b = app.buttons["rss.source.b"].firstMatch
        XCTAssertTrue(b.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(a.exists)
        XCTAssertNotEqual(a.frame.minX, b.frame.minX, "方格必须将不同源并列展示")
        picker.tap(); app.buttons["News"].firstMatch.tap()
        XCTAssertTrue(a.waitForExistence(timeout: 5))
        let hidden = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: b)
        wait(for: [hidden], timeout: 5)
        picker.tap(); app.buttons["全部分類"].firstMatch.tap()
        XCTAssertTrue(b.waitForExistence(timeout: 5))
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "rss-grid"; shot.lifetime = .keepAlways; add(shot)
        app.terminate()
        app = launch(directory)
        app.rootTab("訂閱").tap()
        XCTAssertTrue(app.buttons["rss.sourceGroup"].firstMatch.waitForExistence(timeout: 10), "重新启动记住方格模式")
        menu("樹狀列表", app: app)
        XCTAssertTrue(app.buttons["rss.source.a"].firstMatch.waitForExistence(timeout: 5))
        app.terminate()
    }

    @MainActor func testAccessibleGridReachesLastSource() throws {
        let directory = try fixture()
        defer { do { try FileManager.default.removeItem(at: directory) } catch { XCTFail("测试目录清理失败") } }
        let file = directory.appendingPathComponent("rss_sources.json")
        let seed = try XCTUnwrap((try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [[String: Any]])?.first)
        let sources = (0..<18).map { index -> [String: Any] in
            var value = seed
            value["id"] = "many-\(index)"
            value["name"] = "Source \(index) with a long accessible title"
            value["url"] = "http://127.0.0.1:9/many-\(index)"
            value["sortOrder"] = index
            value.removeValue(forKey: "sourceGroup")
            return value
        }
        try JSONSerialization.data(withJSONObject: sources).write(to: file)
        let app = launch(directory, extra: ["-rss_source_home_grid", "YES", "-AppleInterfaceStyle", "Dark",
            "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"])
        XCTAssertTrue(app.rootTab("訂閱").waitForExistence(timeout: 25)); app.rootTab("訂閱").tap()
        let first = app.buttons["rss.source.many-0"].firstMatch
        XCTAssertTrue(first.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(first.label.contains("long accessible title"), "VoiceOver名称不得因视觉换行截断")
        let last = app.buttons["rss.source.many-17"].firstMatch
        for _ in 0..<10 where !last.exists || !last.isHittable { app.scrollViews.firstMatch.swipeUp(velocity: .slow) }
        XCTAssertTrue(last.exists && last.isHittable, "大字方格最后一行必须可读可点：\(app.debugDescription)")
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "rss-grid-dark-AX5"; shot.lifetime = .keepAlways; add(shot)
        app.terminate()
    }

    @MainActor func testAvailabilityCheckAndConfirmation() throws {
        let directory = try fixture()
        defer { do { try FileManager.default.removeItem(at: directory) } catch { XCTFail("测试目录清理失败") } }
        let app = launch(directory)
        XCTAssertTrue(app.rootTab("訂閱").waitForExistence(timeout: 25)); app.rootTab("訂閱").tap()
        menu("管理訂閱源", app: app)
        let b = app.descendants(matching: .any).matching(identifier: "rss.manage.source.b").firstMatch
        XCTAssertTrue(b.waitForExistence(timeout: 10))
        b.tap()
        app.buttons["rss.manage.check"].tap()
        XCTAssertTrue(app.alerts.firstMatch.waitForExistence(timeout: 5)); app.alerts.firstMatch.buttons["取消"].tap()
        XCTAssertFalse(app.staticTexts["啟動頁已生成（未驗證網路）"].exists)
        app.buttons["rss.manage.check"].tap(); app.alerts.firstMatch.buttons["開始驗證"].tap()
        XCTAssertTrue(app.staticTexts["啟動頁已生成（未驗證網路）"].waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(b.exists, "活性检查不能删除或停用源")
        app.terminate()
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("rss_articles.json").path),
                       "检查不能将文章抓取结果写入持久缓存")
    }

    @MainActor func testMultiselectCancelDeleteAndDeleteAll() throws {
        let directory = try fixture()
        defer { do { try FileManager.default.removeItem(at: directory) } catch { XCTFail("测试目录清理失败") } }
        let app = launch(directory)
        XCTAssertTrue(app.rootTab("訂閱").waitForExistence(timeout: 25)); app.rootTab("訂閱").tap()
        menu("管理訂閱源", app: app)
        let rows = app.descendants(matching: .any)
        let a = rows.matching(identifier: "rss.manage.source.a").firstMatch
        let c = rows.matching(identifier: "rss.manage.source.c").firstMatch
        XCTAssertTrue(a.waitForExistence(timeout: 10), app.debugDescription)
        a.tap(); c.tap()
        app.buttons["rss.manage.delete"].tap()
        let alert = app.alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 5)); alert.buttons["取消"].tap()
        XCTAssertTrue(a.exists && c.exists, "取消不得删除源")
        app.buttons["rss.manage.delete"].tap(); app.alerts.firstMatch.buttons["刪除"].tap()
        let deleted = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: a)
        wait(for: [deleted], timeout: 5)
        XCTAssertFalse(c.exists)
        let b = rows.matching(identifier: "rss.manage.source.b").firstMatch
        XCTAssertTrue(b.exists, "未选源不能随同分类删除")
        app.buttons["rss.manage.selectAll"].tap()
        app.buttons["rss.manage.delete"].tap(); app.alerts.firstMatch.buttons["刪除"].tap()
        let allDeleted = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: b)
        wait(for: [allDeleted], timeout: 5)
        XCTAssertFalse(app.buttons["rss.manage.delete"].isEnabled)
        app.terminate()
        let reloaded = launch(directory)
        reloaded.rootTab("訂閱").tap(); menu("管理訂閱源", app: reloaded)
        XCTAssertTrue(reloaded.staticTexts["沒有訂閱源"].waitForExistence(timeout: 10), "重启后批量删除已落盘")
        reloaded.terminate()
    }
}
