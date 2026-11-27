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

    @MainActor func testGridReturnsToSameScrollPosition() throws {
        try verifySourceReturn(grid: true, collapseFirstFolder: false, swipeBack: false)
    }

    @MainActor func testExpandedTreeReturnsToSameScrollPosition() throws {
        try verifySourceReturn(grid: false, collapseFirstFolder: false, swipeBack: true)
    }

    @MainActor func testPartiallyCollapsedTreeReturnsToSameScrollPosition() throws {
        try verifySourceReturn(grid: false, collapseFirstFolder: true, swipeBack: false)
    }

    @MainActor private func verifySourceReturn(grid: Bool, collapseFirstFolder: Bool, swipeBack: Bool) throws {
        let directory = try fixture()
        defer { do { try FileManager.default.removeItem(at: directory) } catch { XCTFail("测试目录清理失败") } }
        let targetIndex = grid ? 78 : 34
        let file = directory.appendingPathComponent("rss_sources.json")
        let seed = try XCTUnwrap((try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [[String: Any]])?.first)
        let sources = (0..<105).map { index -> [String: Any] in
            seed.merging([
                "id": "return-\(index)", "name": "Return Source \(index)",
                "url": "http://127.0.0.1:9/return-\(index)", "faviconURL": "http://127.0.0.1:9/fixture.png",
                "sortOrder": index, "sourceGroup": index < 22 ? "News" : "Media",
                "enabled": index == targetIndex, "startHtml": "<p>Opened return fixture</p>"
            ]) { _, new in new }
        }
        try JSONSerialization.data(withJSONObject: sources).write(to: file)
        let app = launch(directory, extra: [
            "-rss_main_feed_local_expanded", "YES", "-rss_main_feed_hide_read_feeds", "NO",
            "-rss_source_home_grid", grid ? "YES" : "NO"
        ])
        defer { app.terminate() }
        XCTAssertTrue(app.rootTab("訂閱").waitForExistence(timeout: 25))
        app.rootTab("訂閱").tap()
        let scroll = app.scrollViews.firstMatch
        let news = app.buttons["News"].firstMatch
        let first = app.buttons["rss.source.return-0"].firstMatch
        XCTAssertTrue(first.waitForExistence(timeout: 10))
        if grid { XCTAssertTrue(app.buttons["rss.sourceGroup"].firstMatch.exists) }
        if collapseFirstFolder {
            news.tap()
            XCTAssertTrue(first.waitForNonExistence(timeout: 5))
        }

        let target = app.buttons["rss.source.return-\(targetIndex)"].firstMatch
        for _ in 0..<14 where !target.exists || !target.isHittable { scroll.swipeUp(velocity: .slow) }
        XCTAssertTrue(target.exists && target.isHittable, "测试必须从首页中间点开来源")
        XCTAssertFalse(first.exists && first.isHittable, "点开之前必须已离开首页顶端")
        let before = target.frame
        target.tap()
        XCTAssertTrue(app.webViews.staticTexts["Opened return fixture"].firstMatch.waitForExistence(timeout: 12))
        app.buttons["rss.web.close"].tap()
        XCTAssertTrue(app.buttons["開啟網頁"].firstMatch.waitForExistence(timeout: 8))
        if swipeBack {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.005, dy: 0.55))
                .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.75, dy: 0.55)))
        } else {
            app.navigationBars.buttons["BackButton"].firstMatch.tap()
        }
        XCTAssertTrue(scroll.waitForExistence(timeout: 5))
        XCTAssertTrue(target.exists && target.isHittable, "返回订阅首页后应仍看到刚才打开的来源")
        // iOS 的原生导航栏可在返回时重新展开；允许一行的可视位移，但不能回到列表顶部。
        XCTAssertEqual(target.frame.minY, before.minY, accuracy: before.height, "返回后应留在原来的来源附近")
        XCTAssertFalse(first.exists && first.isHittable)
        if collapseFirstFolder {
            for _ in 0..<14 where !news.exists || !news.isHittable { scroll.swipeDown(velocity: .slow) }
            XCTAssertTrue(news.exists && news.isHittable)
            XCTAssertFalse(first.exists, "导航返回后用户折叠的分组不能自行展开")
        }
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

    @MainActor func testHealthResultPagesOnlySelectAndDeleteCurrentPage() throws {
        let directory = try fixture()
        defer { do { try FileManager.default.removeItem(at: directory) } catch { XCTFail("测试目录清理失败") } }
        let file = directory.appendingPathComponent("rss_sources.json")
        var sources = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [[String: Any]])
        let sample = try XCTUnwrap(sources.first).merging([
            "id": "d", "name": "Delta", "url": "http://127.0.0.1:9/d", "sourceGroup": "Media", "sortOrder": 3
        ]) { _, new in new }
        sources.append(sample)
        try JSONSerialization.data(withJSONObject: sources).write(to: file)

        let app = launch(directory)
        defer { app.terminate() }
        XCTAssertTrue(app.rootTab("訂閱").waitForExistence(timeout: 25)); app.rootTab("訂閱").tap()
        menu("管理訂閱源", app: app)
        let rows = app.descendants(matching: .any)
        let a = rows.matching(identifier: "rss.manage.source.a").firstMatch
        let b = rows.matching(identifier: "rss.manage.source.b").firstMatch
        let c = rows.matching(identifier: "rss.manage.source.c").firstMatch
        let d = rows.matching(identifier: "rss.manage.source.d").firstMatch
        let failures = app.buttons["rss.manage.health.failed"].firstMatch
        let generated = app.buttons["rss.manage.health.generatedPage"].firstMatch
        let all = app.buttons["rss.manage.health.all"].firstMatch
        let selectAll = app.buttons["rss.manage.selectAll"]
        let invert = app.buttons["rss.manage.invertSelection"]
        let delete = app.buttons["rss.manage.delete"]

        XCTAssertTrue(a.waitForExistence(timeout: 10))
        XCTAssertFalse(failures.exists)
        a.tap(); b.tap(); d.tap()
        app.buttons["rss.manage.check"].tap()
        app.alerts.firstMatch.buttons["開始驗證"].tap()
        XCTAssertTrue(failures.waitForExistence(timeout: 12), app.debugDescription)
        XCTAssertTrue(generated.exists)
        XCTAssertTrue(failures.label.hasSuffix(" 2"))
        c.tap()
        XCTAssertTrue(app.staticTexts["已選 4 個"].exists)

        failures.tap()
        XCTAssertTrue(app.staticTexts["已選 0 個"].waitForExistence(timeout: 5), "切结果页清空原勾选")
        XCTAssertTrue(a.exists && d.exists)
        XCTAssertFalse(b.exists || c.exists, "成功和未验证的源不能混入失败页")
        XCTAssertFalse(delete.isEnabled)
        selectAll.tap()
        XCTAssertTrue(app.staticTexts["已選 2 個"].exists)
        invert.tap()
        XCTAssertTrue(app.staticTexts["已選 0 個"].exists)
        invert.tap()
        XCTAssertTrue(app.staticTexts["已選 2 個"].exists)

        generated.tap()
        XCTAssertTrue(b.waitForExistence(timeout: 5))
        XCTAssertFalse(a.exists || c.exists || d.exists)
        XCTAssertTrue(app.staticTexts["已選 0 個"].exists)
        failures.tap()
        selectAll.tap()
        let group = app.buttons["rss.sourceGroup"].firstMatch
        group.tap(); app.buttons["News"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["已選 1 個"].waitForExistence(timeout: 8), "失败页内缩小分组会排除其他组的选择")
        XCTAssertTrue(a.exists)
        XCTAssertFalse(d.exists)
        XCTAssertTrue(failures.label.hasSuffix(" 1"))

        delete.tap()
        let alert = app.alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        XCTAssertTrue(alert.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "選取的 1 個")).firstMatch.exists)
        alert.buttons["取消"].tap()
        XCTAssertTrue(a.exists)
        delete.tap(); alert.buttons["刪除"].tap()
        XCTAssertTrue(a.waitForNonExistence(timeout: 5))

        group.tap(); app.buttons["全部分類"].firstMatch.tap()
        XCTAssertTrue(failures.waitForExistence(timeout: 5))
        all.tap()
        XCTAssertTrue(b.waitForExistence(timeout: 5))
        XCTAssertTrue(c.exists && d.exists, "其他结果和其他分组的失败源均不得删除")
        XCTAssertFalse(a.exists)
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
