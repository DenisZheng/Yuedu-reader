import XCTest

/// S7：Fork 五Tab（探索｜書架｜訂閱｜資源庫｜設定）、搜索入口与订阅模块一致性。
/// 只使用本机空数据，不联网导入、不授予权限。
final class ForkRootTabsUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor
    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "-no-official-modules", "-onboarding.completed", "YES",
            "-yd_icloud_auto_sync", "NO", "-yd_source_disclaimer_accepted", "YES",
            "-AppleLanguages", "(zh-Hant)", "-AppleLocale", "zh_TW"
        ]
        app.launch()
        return app
    }

    @MainActor
    func testDefaultTabsSearchEntriesAndSubscriptionModule() {
        let app = launch()
        let expected = ["探索", "書架", "訂閱", "資源庫", "設定"]
        for title in expected { XCTAssertTrue(app.rootTab(title).waitForExistence(timeout: 30), app.debugDescription) }
        let labels = app.rootTabLabels(expected)
        XCTAssertEqual(labels, expected, "默认Tab顺序：\(labels)\n\(app.debugDescription)")

        // 探索 → 搜索
        app.rootTab("探索").tap()
        let exploreSearch = app.buttons["explore.search"].firstMatch
        XCTAssertTrue(exploreSearch.waitForExistence(timeout: 20))
        exploreSearch.tap()
        XCTAssertTrue(app.searchFields.firstMatch.waitForExistence(timeout: 10), "探索的放大镜应进入搜索页")
        attach(app, "explore-search")

        // 書架 → 搜索
        app.rootTab("書架").tap()
        let shelfSearch = app.buttons["bookshelf.search"].firstMatch
        XCTAssertTrue(shelfSearch.waitForExistence(timeout: 10))
        shelfSearch.tap()
        XCTAssertTrue(app.searchFields.firstMatch.waitForExistence(timeout: 10), "書架的放大镜应进入搜索页")

        // 訂閱Tab根：大标题与新增入口
        app.rootTab("訂閱").tap()
        XCTAssertTrue(app.staticTexts["訂閱"].firstMatch.waitForExistence(timeout: 10))
        attach(app, "subscription-root")

        // 資源庫的訂閱列推入同一模块（推入页inline标题）
        app.rootTab("資源庫").tap()
        let row = app.buttons["library.rss"].firstMatch
        for _ in 0..<8 where !row.exists || !row.isHittable { app.swipeUp(velocity: .slow) }
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.tap()
        XCTAssertTrue(app.navigationBars["RSS 訂閱"].firstMatch.waitForExistence(timeout: 10), "资源库推入同一RSS模块")
    }

    @MainActor
    private func attach(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
