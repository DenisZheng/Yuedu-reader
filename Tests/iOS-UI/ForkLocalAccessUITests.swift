import XCTest

/// 在独立 Fork 中实际操作设置，不注入会员、账号或购买状态。
/// 只打开系统文件选择器，不读取个人文件，也不授予系统权限。
final class ForkLocalAccessUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor
    private func launchSettings() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "-no-official-modules", "-onboarding.completed", "YES",
            "-yd_icloud_auto_sync", "NO", "-yd_source_disclaimer_accepted", "YES",
            "-AppleLanguages", "(en)", "-AppleLocale", "en_US"
        ]
        app.launch()
        let settings = app.buttons.matching(NSPredicate(format: "label == %@", "Settings")).firstMatch
        XCTAssertTrue(settings.waitForExistence(timeout: 30))
        settings.tap()
        XCTAssertFalse(app.buttons["settings_account_row"].exists)
        XCTAssertFalse(app.buttons["paywall_purchase_button"].exists)
        return app
    }

    @MainActor
    private func tapRow(_ app: XCUIApplication, _ title: String) {
        let row = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", title)).firstMatch
        for _ in 0..<10 where !row.exists || !row.isHittable { app.swipeUp(velocity: .slow) }
        XCTAssertTrue(row.waitForExistence(timeout: 10), "Missing settings row: \(title)")
        row.tap()
    }

    @MainActor
    func testFontImportOpensWithoutMembership() {
        let app = launchSettings()
        tapRow(app, "Appearance Theme")
        tapRow(app, "Colors & Font")
        tapRow(app, "Font")
        let importer = app.buttons["global_font_import"].firstMatch
        XCTAssertTrue(importer.waitForExistence(timeout: 10))
        importer.tap()
        let picker = app.descendants(matching: .any).matching(NSPredicate(
            format: "label IN %@ OR identifier IN %@", ["Browse", "Recents"], ["Browse", "Recents"]
        )).firstMatch
        XCTAssertTrue(picker.waitForExistence(timeout: 15), "必须真的打开系统选择器，而非进入付费页")
        XCTAssertFalse(app.buttons["paywall_purchase_button"].exists)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "fork-local-font-import"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    @MainActor
    func testTabCustomizationCanBeChangedWithoutMembership() throws {
        let app = launchSettings()
        tapRow(app, "Appearance Theme")
        tapRow(app, "Tab Bar")
        let toggle = app.switches["root_tabs_custom_size"].firstMatch
        for _ in 0..<8 where !toggle.exists || !toggle.isHittable { app.swipeUp(velocity: .slow) }
        XCTAssertTrue(toggle.waitForExistence(timeout: 10))
        let tree = XCTAttachment(string: app.switches.debugDescription)
        tree.name = "fork-tab-switches-before-tap"
        tree.lifetime = .keepAlways
        add(tree)
        let before = XCTAttachment(screenshot: app.screenshot())
        before.name = "fork-tab-before-tap"
        before.lifetime = .keepAlways
        add(before)
        // SwiftUI 的整行和内部 UISwitch 都出现在可访问性树中；点击原生开关本体，
        // 而非包含 Spacer 的整行中心（该位置不属于可切换的标签文字）。
        let control = toggle.switches.firstMatch
        XCTAssertTrue(control.exists)
        let previous = try XCTUnwrap(control.value as? String)
        defer {
            if control.exists, control.value as? String != previous { control.tap() }
        }
        control.tap()
        let changed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            control.value as? String != previous
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [changed], timeout: 5), .completed)
        XCTAssertFalse(app.buttons["paywall_purchase_button"].exists)
    }

    @MainActor
    func testNotificationStatusIsReadableWithoutRequestingPermission() {
        let app = launchSettings()
        tapRow(app, "RSS Notifications")
        XCTAssertTrue(app.navigationBars["RSS Notifications"].waitForExistence(timeout: 10))
        let status = app.staticTexts.matching(NSPredicate(format: "label IN %@", [
            "Notifications Allowed", "Notifications Off", "Notifications Not Yet Allowed", "Notification Status Unknown"
        ])).firstMatch
        XCTAssertTrue(status.waitForExistence(timeout: 10))
        XCTAssertFalse(app.alerts.element.exists, "读状态不能弹授权提示；本测试不点击允许按钮")
    }
}
