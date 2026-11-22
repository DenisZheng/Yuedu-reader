import XCTest

/// 用 scripts/search_selection_fixture.py 固定慢源请求，验证正在搜索和暂停时都能打开已返回的书。
final class SearchStreamingSelectionUITests: XCTestCase {
    private static let fixture = "http://localhost:18774"
    private var directory: URL!

    override func setUp() async throws {
        continueAfterFailure = false
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SearchStreamingSelection-\(UUID().uuidString)")
        let sources = directory.appendingPathComponent("sources")
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        let definitions: [[String: Any]] = ["fast", "slow"].map { path in
            [
                "bookSourceName": "Selection \(path)",
                "bookSourceUrl": "\(Self.fixture)/\(path)",
                "searchUrl": "\(Self.fixture)/\(path)/search?q={{key}}&page={{page}}",
                "ruleSearch": ["bookList": "class.book", "name": "tag.h3@text",
                               "author": "class.author@text", "bookUrl": "tag.a@href"],
                "ruleBookInfo": ["name": "tag.h1@text", "author": "class.author@text",
                                 "intro": "class.intro@text", "tocUrl": "class.toc@href"],
                "ruleToc": ["chapterList": "tag.li", "chapterName": "tag.a@text", "chapterUrl": "tag.a@href"],
                "enabled": true,
                "lastUpdateTime": Int(Date().timeIntervalSince1970 * 1000),
            ]
        }
        try JSONSerialization.data(withJSONObject: definitions)
            .write(to: sources.appendingPathComponent("book_sources.json"))
        // 公开书库只读本地空结果；关闭官方模块，不使用个人账号或外站。
        try Data("<feed xmlns=\"http://www.w3.org/2005/Atom\"><title>Search</title></feed>".utf8)
            .write(to: directory.appendingPathComponent("ebooks_search.opds.xml"))
        _ = try await control("reset")
    }

    override func tearDown() async throws {
        _ = try await control("release")
        try FileManager.default.removeItem(at: directory)
    }

    private func control(_ action: String) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(from: URL(string: "\(Self.fixture)/\(action)")!)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw NSError(domain: "SearchSelectionFixture", code: 1)
        }
        return data
    }

    @MainActor
    private func beginSearch(fromBookshelf: Bool = false) async throws -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(zh-Hant)", "-AppleLocale", "zh_TW",
                               "-no-official-modules", "-onboarding.completed", "YES",
                               "-yd_source_disclaimer_accepted", "YES",
                               "-book-source-store-dir", directory.appendingPathComponent("sources").path]
        app.launchEnvironment["YUEDU_PUBLIC_LIBRARY_FIXTURES"] = directory.path
        app.launch()
        if fromBookshelf {
            let bookshelf = app.rootTab("書架")
            XCTAssertTrue(bookshelf.waitForExistence(timeout: 30))
            bookshelf.tap()
            let button = app.buttons["bookshelf.search"].firstMatch
            XCTAssertTrue(button.waitForExistence(timeout: 10))
            button.tap()
        } else {
            app.openSearchPage(timeout: 30)
        }
        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        field.typeText("PartialFixture\n")
        XCTAssertTrue(result(in: app).waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons["暫停搜尋"].waitForExistence(timeout: 5), app.debugDescription)
        let state = try JSONSerialization.jsonObject(with: await control("state")) as? [String: Int]
        XCTAssertGreaterThan(state?["pending"] ?? 0, 0, "慢源必须仍在等待，不能用已结束的搜索代替回归。")
        return app
    }

    @MainActor
    private func result(in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH %@", "PartialFixture，")).firstMatch
    }

    @MainActor
    private func openResult(in app: XCUIApplication) {
        let row = result(in: app)
        XCTAssertTrue(row.isHittable, "已出现的结果必须能点击。")
        row.tap()
        let source = app.descendants(matching: .any)["detail.info.source"].firstMatch
        XCTAssertTrue(source.waitForExistence(timeout: 10),
                      "点击必须进入详情页，不能只改变选中状态。\n\(app.debugDescription)")
        XCTAssertEqual(source.value as? String, "Selection fast")
    }

    @MainActor
    func testBookshelfResultOpensBeforeSearchFinishesAndReturnsToResults() async throws {
        let app = try await beginSearch(fromBookshelf: true)
        openResult(in: app)
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(result(in: app).waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["暫停搜尋"].exists, "返回后搜索继续，不能丢掉搜索会话。")
    }

    @MainActor
    func testBookshelfPausedSearchResultOpensAndPauseSurvivesBack() async throws {
        let app = try await beginSearch(fromBookshelf: true)
        app.buttons["暫停搜尋"].tap()
        XCTAssertTrue(app.buttons["繼續搜尋"].waitForExistence(timeout: 5))
        openResult(in: app)
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(result(in: app).waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["繼續搜尋"].exists, "返回后保留手动暂停状态。")
    }
}
