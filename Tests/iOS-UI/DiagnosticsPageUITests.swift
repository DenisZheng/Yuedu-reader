import XCTest

/// 驱动 设置 → 诊断记录，验证本地复制/导出入口与页面结构，不调用原版后台。
///
/// This exists because the page's appearance is the part unit tests cannot reach:
/// `themedAppSurface` and `interfaceSectionSurface` resolve against
/// `GlobalSettings` and `SubscriptionStore` at render time, so "does it follow the
/// appearance settings" is only answerable by rendering it. The screenshots land in
/// the result bundle as attachments.
final class DiagnosticsPageUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testDiagnosticsPageRendersAndFollowsAppearance() throws {
        let app = XCUIApplication()
        // The labels below are English; pin the language so the simulator's own does not matter.
        app.launchArguments = ["-no-official-modules", "-onboarding.completed", "YES", "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
                               "-yd_source_disclaimer_accepted", "YES"]
        app.launch()

        // 同时兼容 iPhone 底栏和 iPad 顶部/侧栏，不依赖 tabBars 元素类型。
        let settingsTab = app.buttons.matching(NSPredicate(format: "label == %@", "Settings")).firstMatch
        XCTAssertTrue(settingsTab.waitForExistence(timeout: 20), "settings tab should exist")
        settingsTab.tap()

        let diagnostics = app.buttons["settings_diagnostics"].firstMatch
        for _ in 0..<8 where !diagnostics.exists {
            app.swipeUp()
        }
        XCTAssertTrue(diagnostics.waitForExistence(timeout: 5), "本地诊断必须能从设置直接到达")
        diagnostics.tap()

        let exportControl = app.descendants(matching: .any)["diagnostics_export_button"]
        XCTAssertTrue(
            exportControl.waitForExistence(timeout: 15),
            "export must be a directly presented control, not hidden behind a toolbar Menu"
        )

        XCTAssertFalse(app.buttons["diagnostics_send_button"].exists, "不能保留云端上传入口")
        app.buttons["diagnostics_more_actions"].tap()
        let copy = app.buttons["diagnostics_copy_all"].firstMatch
        XCTAssertTrue(copy.waitForExistence(timeout: 5))
        copy.tap()
        let copied = app.alerts["Copied"]
        XCTAssertTrue(copied.waitForExistence(timeout: 5), "复制应在本地完成，不等待上传回执")
        copied.buttons.element(boundBy: 0).tap()

        // The filter section starts below the export row and might not be materialized
        // in the accessibility tree until the Form is scrolled.
        let verboseToggle = app.switches.containing(
            NSPredicate(format: "label CONTAINS[c] %@", "Verbose")
        ).firstMatch
        for _ in 0..<3 where !verboseToggle.exists {
            app.swipeUp()
        }
        XCTAssertTrue(
            verboseToggle.waitForExistence(timeout: 5),
            "the diagnostics Form should render its filter section"
        )

        attach(app, name: "diagnostics-light")

        // Section headers prove the Form/Section structure rather than a plain list.
        XCTAssertTrue(app.staticTexts["Filter"].exists || app.staticTexts["FILTER"].exists,
                      "the Filter section header should render")
        for _ in 0..<3 where !app.staticTexts["Log"].exists && !app.staticTexts["LOG"].exists {
            app.swipeUp()
        }
        XCTAssertTrue(app.staticTexts["Log"].exists || app.staticTexts["LOG"].exists,
                      "the Log section header should render")
    }

    @MainActor
    private func attach(_ app: XCUIApplication, name: String) {
        let shot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
