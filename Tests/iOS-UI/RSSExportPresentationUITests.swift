import XCTest

/// Export the same RSS JSON document from the new tab root and the existing Library destination.
/// Each test checks that the system save UI is visible, not merely that the menu action was tapped.
final class RSSExportPresentationUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor
    func testSubscriptionTabPresentsInteractiveJSONSavePicker() {
        let app = launch()
        XCTAssertTrue(app.rootTab("訂閱").waitForExistence(timeout: 20), app.debugDescription)
        app.rootTab("訂閱").tap()
        presentJSONExporter(in: app)
        assertSavePickerVisible(in: app, route: "subscription-tab", saveFile: true)
    }

    @MainActor
    func testLibraryRSSDestinationPresentsInteractiveJSONSavePicker() {
        let app = launch()
        let library = app.rootTab("資源庫")
        XCTAssertTrue(library.waitForExistence(timeout: 20), app.debugDescription)
        library.tap()
        let rss = app.buttons["library.rss"].firstMatch
        for _ in 0..<8 where !rss.exists || !rss.isHittable { app.swipeUp(velocity: .slow) }
        XCTAssertTrue(rss.waitForExistence(timeout: 10), app.debugDescription)
        rss.tap()
        XCTAssertTrue(app.navigationBars["RSS 訂閱"].waitForExistence(timeout: 10), app.debugDescription)
        presentJSONExporter(in: app)
        assertSavePickerVisible(in: app, route: "library-destination")
    }

    @MainActor
    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-no-official-modules", "-onboarding.completed", "YES",
                               "-yd_source_disclaimer_accepted", "YES", "-seed-rss-articles",
                               "-AppleLanguages", "(zh-Hant)", "-AppleLocale", "zh_TW"]
        app.launch()
        return app
    }

    @MainActor
    private func presentJSONExporter(in app: XCUIApplication) {
        let more = app.navigationBars.buttons["更多"].firstMatch
        XCTAssertTrue(more.waitForExistence(timeout: 10), app.debugDescription)
        more.tap()
        let export = app.buttons["匯出 Legado JSON"].firstMatch
        XCTAssertTrue(export.waitForExistence(timeout: 5), app.debugDescription)
        export.tap()
    }

    @MainActor
    private func assertSavePickerVisible(in app: XCUIApplication, route: String, saveFile: Bool = false,
                                         file: StaticString = #filePath, line: UInt = #line) {
        // File Provider can need a cold launch on the first export; wait for its own save action,
        // not an arbitrary delay or RSS's still-visible toolbar controls.
        let save = app.descendants(matching: .any)
            .matching(identifier: "DOCPicker.actionButton").firstMatch
        let localizedSave = app.descendants(matching: .any).matching(
            NSPredicate(format: "label IN %@", ["儲存", "保存", "Save"])
        ).firstMatch
        let picker = NSPredicate { _, _ in save.exists || localizedSave.exists }
        let pickerExpectation = XCTNSPredicateExpectation(predicate: picker, object: app)
        let result = XCTWaiter.wait(for: [pickerExpectation], timeout: 30)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "RSS JSON export save UI — \(route)"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        print("RSS_JSON_EXPORT_UI route=\(route) saveButton=\(save.exists || localizedSave.exists)\n\(app.debugDescription)")
        XCTAssertEqual(result, .completed,
                       "The system JSON save picker did not become interactive from \(route).\n\(app.debugDescription)",
                       file: file, line: line)
        guard saveFile else { return }
        if save.exists {
            save.tap()
        } else {
            // iOS 26.2's legacy AX bridge sometimes exposes the Files Save bar item as a label
            // while its modern accessibility query rejects a tap. Use its reported hit frame
            // for that platform mismatch; this still exercises the actual system save control.
            let frame = localizedSave.frame
            XCTAssertFalse(frame.isEmpty, "The system Save control has no tappable frame")
            app.coordinate(withNormalizedOffset: CGVector(dx: frame.midX / app.frame.width,
                                                           dy: frame.midY / app.frame.height)).tap()
        }
        let saveAlert = app.alerts.firstMatch
        if saveAlert.waitForExistence(timeout: 2) {
            let replace = saveAlert.buttons.matching(
                NSPredicate(format: "label IN %@", ["取代", "替换", "Replace", "Overwrite"])
            ).firstMatch
            XCTAssertTrue(replace.exists,
                          "Unexpected alert after saving RSS JSON.\n\(saveAlert.debugDescription)")
            replace.tap()
        }
        let more = app.navigationBars.buttons["更多"].firstMatch
        if more.isHittable {
            // Some OS versions complete the export and return to the caller immediately.
            XCTAssertTrue(more.waitForExistence(timeout: 10))
        } else {
            // Others keep the Files document browser open after saving. The exported file itself
            // must appear in the selected folder; presenting the picker alone is not success.
            let exportedFile = app.descendants(matching: .any).matching(
                NSPredicate(format: "label CONTAINS %@", "yuedu-rss-legado.json")
            ).firstMatch
            XCTAssertTrue(exportedFile.waitForExistence(timeout: 20),
                          "Save did not create the requested Legado JSON file.\n\(app.debugDescription)")
        }
        XCTAssertFalse(app.alerts.firstMatch.exists, "The JSON export reported an error after saving")
    }
}
