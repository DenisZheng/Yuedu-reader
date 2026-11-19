import UIKit
import XCTest

/// 改编自上游5905b06d：沿Fork探索入口推入搜索，不恢复独立搜索Tab。
/// 空书源及隔离书架，只用合成最近记录，不请求真实源或触碰用户书架。
final class SearchRecentsTapUITests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        continueAfterFailure = false
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("SearchRecentsTap-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        XCUIApplication().terminate()
        if let directory { try FileManager.default.removeItem(at: directory) }
    }

    @MainActor
    private func launch(readingRecord: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "-AppleLanguages", "(zh-Hant)", "-AppleLocale", "zh_TW",
            "-no-official-modules", "-onboarding.completed", "YES",
            "-yd_icloud_auto_sync", "NO", "-yd_source_disclaimer_accepted", "YES",
            "-shelf-test-dir", directory.path, "-book-source-store-dir", directory.path,
            "-yd_search_recent_reading_cleared_at", "0",
            "-yd_search_recent_queries", readingRecord ? #""[]""# : #""[\"FB195\"]""#,
            "-yd_off_shelf_read_records", readingRecord
                ? #""[{\"title\":\"FB195-Reading\",\"author\":\"Fixture\",\"coverUrl\":\"\",\"lastRead\":1000}]""#
                : #""[]""#
        ]
        app.launch()
        let explore = app.rootTab("探索")
        XCTAssertTrue(explore.waitForExistence(timeout: 30))
        explore.tap()
        let entry = app.buttons["explore.search"].firstMatch
        XCTAssertTrue(entry.waitForExistence(timeout: 20))
        entry.tap()
        XCTAssertTrue(app.searchFields.firstMatch.waitForExistence(timeout: 10))
        return app
    }

    @MainActor
    func testTappingARecentSearchRunsIt() {
        let app = launch()
        let recent = app.buttons["FB195"].firstMatch
        XCTAssertTrue(recent.waitForExistence(timeout: 10), "未激活搜索框时应保留最近搜索")
        recent.tap()
        assertQuery("FB195", in: app)
    }

    @MainActor
    func testTappingARecentReadingRecordSearchesForIt() {
        let app = launch(readingRecord: true)
        let recent = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "FB195-Reading")).firstMatch
        XCTAssertTrue(recent.waitForExistence(timeout: 10), "未激活搜索框时应保留最近阅读")
        recent.tap()
        assertQuery("FB195-Reading", in: app)
    }

    @MainActor
    func testActiveEmptySearchDoesNotLoseRecentAfterFirstTap() {
        let app = launch()
        app.searchFields.firstMatch.tap()
        let recent = app.buttons["FB195"].firstMatch
        XCTAssertTrue(recent.waitForExistence(timeout: 10))
        recent.tap()
        if UIDevice.current.userInterfaceIdiom == .pad {
            // iPad系统先把列表触摸作为结束搜索，条目必须仍在，第二次点击可执行。
            XCTAssertTrue(recent.waitForExistence(timeout: 10))
            recent.tap()
        }
        assertQuery("FB195", in: app)
    }

    @MainActor
    private func assertQuery(_ query: String, in app: XCUIApplication) {
        expectation(for: NSPredicate(format: "value == %@", query), evaluatedWith: app.searchFields.firstMatch)
        waitForExpectations(timeout: 10)
        XCTAssertFalse(app.staticTexts["輸入書名或作者搜尋"].firstMatch.exists)
    }
}
