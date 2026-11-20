import XCTest

/// 仅操作员显式传入单条测试源时运行。只点开订阅网页，不操作真人验证、不刷新或执行页面动作。
final class RSSRealSourceOpeningUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor
    func testOpenSingleSourceWithoutChallengeInteraction() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let input = environment["RSS_REAL_OPENING_INPUT"],
              let storage = environment["RSS_REAL_OPENING_STORE"] else {
            throw XCTSkip("实源首屏测试需要操作员单独授权和提供输入")
        }
        let data = try Data(contentsOf: URL(fileURLWithPath: input))
        let entries = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        XCTAssertEqual(entries.count, 1, "只允许一条预审过的输入")
        let entry = try XCTUnwrap(entries.first)
        let address = try XCTUnwrap(entry["sourceUrl"] as? String)
        let url = try XCTUnwrap(URLComponents(string: address))
        XCTAssertEqual(url.scheme, "https")
        XCTAssertNotNil(url.host)
        XCTAssertNil(url.user); XCTAssertNil(url.password); XCTAssertNil(url.query); XCTAssertNil(url.fragment)
        XCTAssertNil(entry["header"], "本用例只测未声明 UA 的原生网页")
        for key in ["singleUrl", "enableJs", "enabledCookieJar"] {
            XCTAssertEqual(entry[key] as? Bool, true, "输入必须走原生网页")
        }
        XCTAssertEqual(entry["cacheFirst"] as? Bool, false)
        let directory = URL(fileURLWithPath: storage, isDirectory: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path), "不覆盖既有测试或用户数据")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let source: [String: Any] = [
            "id": "real-opening-fixture", "name": "RSS opening fixture", "url": address,
            "homepageURL": "https://127.0.0.1:9/", "faviconURL": "https://127.0.0.1:9/icon.png",
            "enabled": true, "newArticleNotificationsEnabled": false, "sortOrder": 0,
            "articleStyle": 0, "customOrder": 0, "lastUpdateTime": 0,
            "singleUrl": true, "enableJs": true, "enabledCookieJar": true,
            "loadWithBaseUrl": true, "cacheFirst": false, "importedFromLegado": true
        ]
        // 图标只指向本机拒绝端口，避免点开网页前额外抓取实站；不改变网页 URL 或请求身份。
        try JSONSerialization.data(withJSONObject: [source]).write(to: directory.appendingPathComponent("rss_sources.json"))
        let app = XCUIApplication()
        app.launchArguments = ["-no-official-modules", "-onboarding.completed", "YES", "-yd_icloud_auto_sync", "NO",
            "-yd_source_disclaimer_accepted", "YES", "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
            "-rss-store-dir", directory.path, "-rss_main_feed_smart_feeds_expanded", "NO",
            "-rss_main_feed_local_expanded", "YES", "-rss_main_feed_hide_read_feeds", "NO"]
        app.launch()
        let tab = app.rootTab("Subscriptions")
        XCTAssertTrue(tab.waitForExistence(timeout: 25), "订阅入口未显示")
        tab.tap()
        let sourceButton = app.buttons["rss.source.real-opening-fixture"].firstMatch
        XCTAssertTrue(sourceButton.waitForExistence(timeout: 10), "单条测试源未显示")
        sourceButton.tap()
        XCTAssertTrue(app.buttons["rss.web.close"].waitForExistence(timeout: 20), "原生网页容器未显示")
        XCTAssertTrue(app.webViews.firstMatch.waitForExistence(timeout: 10), "WebKit 页面未创建")
        // 观察首屏而非验证功能通过；只要见到验证或 403 就停止自动操作。
        let rejected = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "HTTP 403")).firstMatch
        let challenge = app.webViews.staticTexts.matching(NSPredicate(format:
            "label CONTAINS[c] %@ OR label CONTAINS[c] %@", "Verify you are human", "Cloudflare")).firstMatch
        let observation = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            rejected.exists || challenge.exists
        }, object: nil)
        let result = XCTWaiter.wait(for: [observation], timeout: 12)
        print("[RSSRealOpening] containerOpened=true http403Overlay=\(rejected.exists) challengeVisible=\(challenge.exists) observationCompleted=\(result == .completed) automatedChallengeClicks=0")
        // 独立测试数据保留供操作员手动查看；不删除原始包、不把首屏可见当作验证成功。
    }
}
