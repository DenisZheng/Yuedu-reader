import XCTest

/// 用户给出的YCK205按钮入口：不刷新源、不执行源规则，也不确认写库。
final class ReviewYCK205ImportUITests: XCTestCase {
    @MainActor func testWebsiteOneKeyImportShowsRSSRows() throws {
        guard ProcessInfo.processInfo.environment["YUEDU_RUN_YCK205_IMPORT"] == "1" else {
            throw XCTSkip("公网导入验收须显式授权并单独运行")
        }
        continueAfterFailure = false
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("yck205-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { do { try FileManager.default.removeItem(at: directory) } catch { XCTFail("隔离目录清理失败") } }
        let name = "YCK205入口测试"
        let source: [String: Any] = [
            "bookSourceName": name, "bookSourceUrl": "https://fixture.invalid/yck205",
            "exploreUrl": #"[{"title":"导入测试","url":"java.startBrowser('https://www.yckceo.com/yuedu/rsss/content/id/205.html','YCK205')"}]"#,
            "enabled": true, "enabledExplore": true
        ]
        try JSONSerialization.data(withJSONObject: [source]).write(to: directory.appendingPathComponent("book_sources.json"))
        let app = XCUIApplication()
        app.launchArguments = ["-no-official-modules", "-onboarding.completed", "YES", "-AppleLanguages", "(zh-Hant)",
                               "-AppleLocale", "zh_TW", "-yd_source_disclaimer_accepted", "YES",
                               "-book-source-store-dir", directory.path, "-reset-explore-home"]
        app.launch()
        defer { app.terminate() }
        let library = app.tabBars.buttons["資源庫"].firstMatch
        XCTAssertTrue(library.waitForExistence(timeout: 30), "资源库未出现")
        library.tap()
        let all = app.buttons["library.sources.all"].firstMatch
        for _ in 0..<6 where !all.exists { app.scrollViews.firstMatch.swipeUp(velocity: .slow) }
        XCTAssertTrue(all.waitForExistence(timeout: 10)); all.tap()
        let item = app.buttons["library.source.\(name)"].firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 10)); item.tap()
        let page = app.buttons["导入测试"].firstMatch
        XCTAssertTrue(page.waitForExistence(timeout: 15)); page.tap()
        let link = app.webViews.links.matching(NSPredicate(format: "label CONTAINS %@", "3.x一键导入")).firstMatch
        XCTAssertTrue(link.waitForExistence(timeout: 30), "网页未出现用户指定的导入按钮")
        link.tap()
        let alert = app.alerts.firstMatch
        if alert.waitForExistence(timeout: 3) {
            let confirm = alert.buttons.matching(NSPredicate(format: "label == %@ OR label == %@ OR label == %@", "確定", "確認", "完成")).firstMatch
            XCTAssertTrue(confirm.exists, "导入确认没有可激活按钮"); confirm.tap()
        }
        let download = app.buttons["確認匯入"].firstMatch
        XCTAssertTrue(download.waitForExistence(timeout: 5), "网站深链没有进入统一确认页")
        download.tap()
        let summary = app.staticTexts["rss-import-summary"].firstMatch
        let hasSummary = summary.waitForExistence(timeout: 20)
        XCTAssertTrue(hasSummary, "网页一键导入未进入有内容的RSS比较预览")
        XCTAssertTrue(summary.label.contains("新增 36") || summary.label.contains("更新 36") || !summary.label.contains("新增 0、更新 0、跳過 0、錯誤 0"), "用户实源不能得到空导入列表")
        print("YCK205_IMPORT_PREVIEW \(summary.label) saved=false refreshed=false")
        let confirm = app.buttons["rss-import-confirm"].firstMatch
        XCTAssertTrue(confirm.exists && confirm.isEnabled, "RSS预览没有可选订阅")
        app.buttons["rss-import-close"].firstMatch.tap()
    }
}
