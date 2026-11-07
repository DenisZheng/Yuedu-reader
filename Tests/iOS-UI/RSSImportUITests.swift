import XCTest

final class RSSImportUITests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        continueAfterFailure = false
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("RSSImportUI-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let input = Data(#"[{"sourceUrl":"fixture#opaque","sourceName":"Import Fixture","enabled":false,"future":{"n":1}},{"sourceName":"Missing Key"}]"#.utf8)
        try input.write(to: directory.appendingPathComponent("rss-import-fixture.json"))
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
    }

    @MainActor
    private func launch(accessibilitySize: Bool) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-rss-poc-isolated-host", "-AppleLanguages", "(zh-Hant)", "-AppleLocale", "zh_TW"]
        if accessibilitySize { app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"] }
        app.launchEnvironment["RSS_IMPORT_UI_FIXTURE"] = directory.appendingPathComponent("rss-import-fixture.json").path
        app.launchEnvironment["RSS_IMPORT_UI_STORAGE"] = directory.path
        app.launch()
        XCTAssertTrue(app.buttons["rss-fixture-open"].waitForExistence(timeout: 15))
        return app
    }

    @MainActor
    func testCancelThenConfirmAndReimport() throws {
        let app = launch(accessibilitySize: false)
        defer { app.terminate() }
        app.buttons["rss-fixture-open"].tap()
        XCTAssertTrue(app.staticTexts["rss-import-summary"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["rss-import-close"].isHittable)
        app.buttons["rss-import-close"].tap()
        XCTAssertTrue(app.buttons["rss-fixture-open"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["rss-fixture-saved-count"].label, "0")
        app.buttons["rss-fixture-open"].tap()
        XCTAssertTrue(app.buttons["rss-import-confirm"].waitForExistence(timeout: 10))
        app.buttons["rss-import-confirm"].tap()
        XCTAssertTrue(app.staticTexts["rss-import-result"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["rss-import-result"].label.contains("新增 1"))
        app.buttons["rss-import-close"].tap()
        XCTAssertTrue(app.buttons["rss-fixture-open"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["rss-fixture-saved-count"].label, "1")
        app.buttons["rss-fixture-open"].tap()
        XCTAssertTrue(app.staticTexts["rss-import-summary"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["rss-import-confirm"].isEnabled)
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.lifetime = .keepAlways; add(shot)
    }

    @MainActor
    func testAccessibilitySizeKeepsConfirmationReachable() throws {
        let app = launch(accessibilitySize: true)
        defer { app.terminate() }
        app.buttons["rss-fixture-open"].tap()
        XCTAssertTrue(app.buttons["rss-import-confirm"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["rss-import-confirm"].isHittable)
        XCTAssertTrue(app.buttons["rss-import-close"].isHittable)
        XCTAssertFalse(app.buttons["rss-import-confirm"].label.isEmpty)
        app.buttons["rss-import-confirm"].tap()
        XCTAssertTrue(app.staticTexts["rss-import-result"].waitForExistence(timeout: 10))
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.lifetime = .keepAlways; add(shot)
    }
}
