import XCTest

/// 直接操作生产独立网页工具栏与DOM关闭按钮；隔离宿主只提供合成页面，不接触用户数据。
final class RSSWebDisplayUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor
    func testTwoPanelsCanCloseAndPageKeepsState() {
        let original = XCUIDevice.shared.orientation
        XCUIDevice.shared.orientation = .portrait
        defer { XCUIDevice.shared.orientation = original }
        let app = launch(largeText: false, dark: false)
        defer { app.terminate() }
        open(app)
        XCTAssertTrue(app.buttons["rss.web.close"].isHittable)
        selectScale("10%", in: app)
        closePanels(in: app)
        let action = app.webViews.buttons["Action 0"].firstMatch
        XCTAssertTrue(action.waitForExistence(timeout: 5), app.debugDescription)
        action.tap()
        XCTAssertTrue(app.webViews.buttons["Action 1"].waitForExistence(timeout: 5), app.debugDescription)
        selectScale("100%", in: app)
        XCTAssertTrue(app.webViews.buttons["Action 1"].exists, "缩放不能重载页面或重置脚本状态")
        attach(app, "panels-closed-state-preserved")
        close(app)
        open(app)
        XCTAssertEqual(app.buttons["rss.web.scale"].label, "Page Zoom: 100%", "重开不保留上次页面缩放")
        close(app)
    }

    @MainActor
    func testClientSideWebBackReturnsToPageWithoutClosingSheet() {
        checkWebBack(largeText: false, dark: false)
    }

    @MainActor
    func testWebBackAndCloseStayReachableAtAX5() {
        checkWebBack(largeText: true, dark: true)
    }

    @MainActor
    private func checkWebBack(largeText: Bool, dark: Bool) {
        let app = launch(largeText: largeText, dark: dark)
        defer { app.terminate() }
        open(app)
        XCTAssertFalse(app.buttons["rss.web.back"].exists)
        let openChild = app.webViews.buttons["Open child page"]
        XCTAssertTrue(openChild.waitForExistence(timeout: 5), app.debugDescription)
        openChild.tap()
        XCTAssertTrue(app.webViews.staticTexts["Child page"].waitForExistence(timeout: 5), app.debugDescription)
        let webBack = app.buttons["rss.web.back"]
        XCTAssertTrue(webBack.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(app.buttons["rss.web.close"].isHittable)
        XCTAssertTrue(webBack.isHittable)
        attach(app, largeText ? "web-history-child-ax5" : "web-history-child")

        webBack.tap()
        XCTAssertTrue(app.webViews.staticTexts["Home page"].waitForExistence(timeout: 5), app.debugDescription)
        let hiddenBack = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: webBack)
        XCTAssertEqual(XCTWaiter.wait(for: [hiddenBack], timeout: 5), .completed, app.debugDescription)
        XCTAssertTrue(app.buttons["rss.web.close"].isHittable, "网页后退不能关闭整个阅读界面")
        XCTAssertTrue(app.webViews.firstMatch.exists)
        attach(app, largeText ? "web-history-home-ax5" : "web-history-home")
        close(app)
        open(app)
        XCTAssertFalse(app.buttons["rss.web.back"].exists, "重开后不能保留旧页面的历史操作")
        close(app)
    }

    @MainActor
    func testNativeCloseStaysReachableAtAX5AndDark() {
        let original = XCUIDevice.shared.orientation
        XCUIDevice.shared.orientation = .portrait
        defer { XCUIDevice.shared.orientation = original }
        let app = launch(largeText: true, dark: true)
        defer { app.terminate() }
        open(app)
        attach(app, "ax5-dark-original-panel")
        XCTAssertTrue(app.buttons["rss.web.close"].isHittable)
        close(app)
        open(app)
        selectScale("10%", in: app)
        XCTAssertTrue(app.buttons["rss.web.close"].isHittable)
        attach(app, "ax5-dark-scaled-panel")
        close(app)
    }

    @MainActor
    func testLandscapeClosePanelsAndReset() {
        let original = XCUIDevice.shared.orientation
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = original }
        let app = launch(largeText: false, dark: true)
        defer { app.terminate() }
        open(app)
        selectScale("10%", in: app)
        closePanels(in: app)
        selectScale("100%", in: app)
        XCTAssertTrue(app.buttons["rss.web.close"].isHittable)
        attach(app, "landscape-panels-closed")
        close(app)
    }

    @MainActor
    private func launch(largeText: Bool, dark: Bool) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-rss-poc-isolated-host", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        if largeText { app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"] }
        app.launchEnvironment["RSS_WEB_DISPLAY_FIXTURE"] = "1"
        app.launchEnvironment["RSS_WEB_DISPLAY_DARK"] = dark ? "1" : "0"
        app.launch()
        XCTAssertTrue(app.buttons["rss.web.fixture.open"].waitForExistence(timeout: 15), app.debugDescription)
        return app
    }

    @MainActor
    private func open(_ app: XCUIApplication) {
        app.buttons["rss.web.fixture.open"].tap()
        XCTAssertTrue(app.buttons["rss.web.scale"].waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(app.webViews.firstMatch.waitForExistence(timeout: 10), app.debugDescription)
    }

    @MainActor
    private func close(_ app: XCUIApplication) {
        app.buttons["rss.web.close"].tap()
        let open = app.buttons["rss.web.fixture.open"]
        let visible = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hittable == true"), object: open)
        XCTAssertEqual(XCTWaiter.wait(for: [visible], timeout: 5), .completed, app.debugDescription)
        XCTAssertFalse(app.webViews.firstMatch.exists)
    }

    @MainActor
    private func selectScale(_ label: String, in app: XCUIApplication) {
        let menu = app.buttons["rss.web.scale"]
        menu.tap()
        let option = app.buttons[label].firstMatch
        XCTAssertTrue(option.waitForExistence(timeout: 5), app.debugDescription)
        option.tap()
        let selected = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "Page Zoom: " + label), object: menu)
        XCTAssertEqual(XCTWaiter.wait(for: [selected], timeout: 5), .completed, app.debugDescription)
    }

    @MainActor
    private func closePanels(in app: XCUIApplication) {
        for title in ["Close panel 1", "Close panel 2"] {
            let button = app.webViews.buttons[title].firstMatch
            XCTAssertTrue(button.waitForExistence(timeout: 10), app.debugDescription)
            let inside = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                button.exists && button.isHittable && app.webViews.firstMatch.frame.contains(button.frame)
            }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [inside], timeout: 8), .completed, app.debugDescription)
            button.tap()
        }
        XCTAssertFalse(app.webViews.buttons["Close panel 1"].exists)
        XCTAssertFalse(app.webViews.buttons["Close panel 2"].exists)
    }

    @MainActor
    private func attach(_ app: XCUIApplication, _ name: String) {
        let image = XCTAttachment(screenshot: app.screenshot())
        image.name = name; image.lifetime = .keepAlways; add(image)
    }
}
