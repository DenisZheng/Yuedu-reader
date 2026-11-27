import XCTest

/// 启动普通 Debug App，实际点订阅页。响应仅来自本机脚本，不导入真实源包。
final class RSSRuleListOpeningUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor
    func testOpenRuleListsAndRetryFromSubscriptions() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let port = environment["RSS_RULE_OPENING_FIXTURE_PORT"].flatMap(UInt16.init), port != 0 else {
            throw XCTSkip("需要启动 scripts/rss_rule_opening_fixture.py 并传入本机端口")
        }
        let root = "http://127.0.0.1:\(port)"
        let directory = try seed(root: root)
        let app = XCUIApplication()
        defer {
            app.terminate()
            do { try FileManager.default.removeItem(at: directory) } catch { XCTFail("测试目录清理失败") }
        }
        app.launchArguments = ["-no-official-modules", "-onboarding.completed", "YES", "-yd_icloud_auto_sync", "NO",
            "-yd_source_disclaimer_accepted", "YES", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN",
            "-rss-store-dir", directory.path, "-rss_main_feed_smart_feeds_expanded", "NO",
            "-rss_main_feed_local_expanded", "YES", "-rss_main_feed_hide_read_feeds", "NO", "-rss_source_home_grid", "NO"]
        app.launch()
        let tab = app.rootTab("订阅")
        XCTAssertTrue(tab.waitForExistence(timeout: 25))
        tab.tap()

        let stream = app.buttons["rss.source.fixture-stream"].firstMatch
        XCTAssertTrue(stream.waitForExistence(timeout: 10))
        stream.tap()
        XCTAssertTrue(article("本机随机分类条目", in: app).waitForExistence(timeout: 12), app.debugDescription)
        XCTAssertFalse(app.staticTexts["RSS 源脚本执行失败，请查看诊断"].exists)
        attach("rss-fixture-random-list", app: app)

        app.navigationBars.buttons["BackButton"].firstMatch.tap()
        let gated = app.buttons["rss.source.fixture-gate"].firstMatch
        XCTAssertTrue(gated.waitForExistence(timeout: 10))
        gated.tap()
        let error = app.staticTexts["无法完成 RSS 请求（HTTP 403）"].firstMatch
        XCTAssertTrue(error.waitForExistence(timeout: 12), app.debugDescription)
        let retry = app.buttons["重试"].firstMatch
        XCTAssertTrue(retry.isHittable)
        XCTAssertTrue(app.buttons["以网页打开"].firstMatch.exists)
        XCTAssertFalse(article("不应显示的拒绝页条目", in: app).exists)
        attach("rss-fixture-http-403", app: app)

        retry.tap()
        XCTAssertTrue(article("本机列表重试条目", in: app).waitForExistence(timeout: 12), app.debugDescription)
        XCTAssertFalse(error.exists)
        attach("rss-fixture-http-retry", app: app)
    }

    @MainActor
    private func article(_ title: String, in app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "rss.article.", title)).firstMatch
    }

    @MainActor
    private func attach(_ name: String, app: XCUIApplication) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name; shot.lifetime = .keepAlways; add(shot)
    }

    private func seed(root: String) throws -> URL {
        let directory = URL.temporaryDirectory.appendingPathComponent("RSSRuleListUI-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let common: [String: Any] = [
            "faviconURL": root + "/icon.png", "enabled": true, "newArticleNotificationsEnabled": false,
            "customOrder": 0, "lastUpdateTime": 0, "enableJs": true, "enabledCookieJar": false,
            "singleUrl": false, "importedFromLegado": true, "loadWithBaseUrl": true
        ]
        let stream: [String: Any] = [
            "id": "fixture-stream", "name": "随机列表（本机样本）", "url": root + "/stream/", "articleStyle": 1, "sortOrder": 0,
            "sortUrl": "随机::/stream/list?page={{Math.ceil(Math.random()*1500)}}",
            "ruleArticles": "$.rescont.data[*]", "ruleTitle": "$.title", "ruleLink": "/stream/article/{{$.id}}",
            "ruleImage": "{{$.coverbase64.url}}", "coverDecodeJs": """
            var out = new Packages.java.io.ByteArrayOutputStream(), buffer = java.strToBytes(' '.repeat(4096)), n;
            while ((n = result.read(buffer)) !== -1) out.write(buffer, 0, n);
            var text = java.bytesToStr(out.toByteArray(), 'UTF-8');
            java.base64DecodeToByteArray(text.substring(text.indexOf(',') + 1));
            """
        ]
        let gate: [String: Any] = [
            "id": "fixture-gate", "name": "403 列表（本机样本）", "url": root + "/gate/#variant", "articleStyle": 0, "sortOrder": 1,
            "sortUrl": """
            @js:
            const body = java.ajax(String(source.getKey()).split('#')[0] + 'categories');
            '最新::' + org.jsoup.Jsoup.parse(body).select('a').attr('href') + '?mode=async&from={{page}}';
            """,
            "header": "<js>JSON.stringify({'X-RSS-Fixture':'local'})</js>",
            "ruleArticles": "class.entry", "ruleTitle": "tag.a@text", "ruleLink": "tag.a@href"
        ]
        let sources = [stream, gate].map { common.merging($0) { _, value in value } }
        try JSONSerialization.data(withJSONObject: sources).write(to: directory.appendingPathComponent("rss_sources.json"))
        return directory
    }
}
