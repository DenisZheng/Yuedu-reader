import XCTest

/// 每次自建唯一的 Files 样本和规则库，实际走原管理页、系统选择器和预览。
final class ReplaceRuleImportUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor
    func testMixedFileShowsAllRowsCancelsThenImportsOnlySupported() throws {
        #if !targetEnvironment(simulator)
        throw XCTSkip("需要模拟器的 Files 夹具目录")
        #else
        let token = UUID().uuidString
        let directory = URL.temporaryDirectory.appendingPathComponent("ReplaceRuleImportUITests-\(token)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { removeFixture(directory) }
        let rulesFile = directory.appendingPathComponent("replace-rules.json")
        let stem = "replace-review-\(token)"
        let name = "驗收正文 \(token.prefix(8))"
        let scope = "https://fixture.invalid/feed?editions=morning,evening"
        let data = Data("""
            [
            {"id":42,"name":"\(name)","pattern":"A","replacement":"","replace":"B","scope":"\(scope)"},
            {"id":43,"pattern":"标题","scopeTitle":true,"scopeContent":false},
            {"id":44,"pattern":"保留","excludeScope":"保留本"},
            {"id":45,"pattern":"(","isRegex":true},
            null
            ]
            """.utf8)
        let staged = try stageInFiles(data, name: stem + ".json")
        defer { removeFixture(staged) }

        let app = XCUIApplication()
        app.launchArguments = ["-rss-poc-isolated-host", "-AppleLanguages", "(zh-Hant)", "-AppleLocale", "zh_TW"]
        app.launchEnvironment["REPLACE_RULE_IMPORT_UI_STORAGE"] = directory.path
        app.launch()
        defer { app.terminate() }
        let entry = app.buttons["replace-rule-fixture-open"]
        XCTAssertTrue(entry.waitForExistence(timeout: 15), app.debugDescription)
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: entry)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 5), .completed)
        entry.tap()

        selectFixture(in: app, stem: stem)
        let preview = app.navigationBars["替換規則匯入預覽"]
        XCTAssertTrue(preview.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(app.staticTexts["1 條可匯入，4 條將略過"].waitForExistence(timeout: 10))
        let labels = app.descendants(matching: .any)
        for text in ["第 1 條規則", "scopeTitle, scopeContent", "excludeScope", "無效的欄位：pattern", "規則格式無效"] {
            let row = labels.matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
            for _ in 0..<3 where !row.exists { app.swipeUp() }
            XCTAssertTrue(row.exists, "預覽缺少 \(text)")
        }
        preview.buttons["取消"].tap()
        XCTAssertTrue(app.navigationBars["替換規則"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts[name].exists)
        XCTAssertFalse(FileManager.default.fileExists(atPath: rulesFile.path))

        selectFixture(in: app, stem: stem)
        let confirm = preview.buttons["匯入可支援的規則"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 10), app.debugDescription)
        confirm.tap()
        XCTAssertTrue(app.staticTexts["已匯入 1 條替換規則"].waitForExistence(timeout: 10))
        preview.buttons["關閉"].tap()
        XCTAssertTrue(app.staticTexts[name].waitForExistence(timeout: 5))
        let saved = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: rulesFile)) as? [[String: Any]])
        XCTAssertEqual(saved.count, 1)
        XCTAssertEqual(saved.first?["replacement"] as? String, "B")
        XCTAssertEqual(saved.first?["scope"] as? String, scope)
        app.navigationBars["替換規則"].buttons["完成"].tap()
        let audited = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value IN %@", ["unchanged", "changed"]), object: entry)
        XCTAssertEqual(XCTWaiter.wait(for: [audited], timeout: 5), .completed)
        XCTAssertEqual(entry.value as? String, "unchanged", "规则页不应修改标准偏好域")
        #endif
    }

    @MainActor
    private func stageInFiles(_ bytes: Data, name: String) throws -> URL {
        let files = XCUIApplication(bundleIdentifier: "com.apple.DocumentsApp")
        files.launch()
        files.terminate()
        let containers = URL(fileURLWithPath: NSHomeDirectory())
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let groups = containers.appendingPathComponent("Shared/AppGroup")
        let local = try FileManager.default.contentsOfDirectory(at: groups, includingPropertiesForKeys: nil).first { group in
            let metadata = group.appendingPathComponent(".com.apple.mobile_container_manager.metadata.plist")
            guard FileManager.default.fileExists(atPath: metadata.path) else { return false }
            let plist = try PropertyListSerialization.propertyList(from: Data(contentsOf: metadata), format: nil) as? [String: Any]
            return plist?["MCMMetadataIdentifier"] as? String == "group.com.apple.FileProvider.LocalStorage"
        }
        let file = try XCTUnwrap(local, "找不到模拟器 Files 本机目录")
            .appendingPathComponent("File Provider Storage").appendingPathComponent(name)
        try bytes.write(to: file, options: .withoutOverwriting)
        return file
    }

    private func removeFixture(_ file: URL) {
        do { try FileManager.default.removeItem(at: file) }
        catch { XCTFail("无法清理本次测试的夹具") }
    }

    @MainActor
    private func selectFixture(in app: XCUIApplication, stem: String) {
        app.navigationBars["替換規則"].buttons["新增或匯入"].tap()
        let route = app.buttons["匯入替換規則 JSON"].firstMatch
        XCTAssertTrue(route.waitForExistence(timeout: 5), app.debugDescription)
        route.tap()
        let filename = app.cells.matching(NSPredicate(format: "label BEGINSWITH %@", stem)).firstMatch
        if filename.waitForExistence(timeout: 5) { filename.tap(); return }
        let browse = app.buttons.matching(NSPredicate(format: "label IN %@", ["瀏覽", "Browse"])).firstMatch
        XCTAssertTrue(browse.waitForExistence(timeout: 10), app.debugDescription)
        browse.tap()
        if filename.exists { filename.tap(); return }
        let local = app.cells.matching(NSPredicate(format: "label IN %@", ["我的iPhone", "我的 iPhone", "On My iPhone"])).firstMatch
        if !local.exists, !filename.exists, browse.isHittable { browse.tap() }
        XCTAssertTrue(local.waitForExistence(timeout: 8), app.debugDescription)
        local.tap()
        XCTAssertTrue(filename.waitForExistence(timeout: 8), app.debugDescription)
        filename.tap()
    }
}
