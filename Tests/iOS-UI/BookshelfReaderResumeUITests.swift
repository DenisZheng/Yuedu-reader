import UIKit
import XCTest

/// 隔离书库中的自建 TXT：实际翻页和退出后重开，不能把开书动画中短暂出现的正文算成功。
final class BookshelfReaderResumeUITests: XCTestCase {
    private let title = "ReaderResumeFixture"
    private let bodyMarker = "书架继续阅读回归正文"
    private var directory: URL!

    override func setUpWithError() throws {
        continueAfterFailure = false
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BookshelfReaderResume-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let text = "第一章 开始\n\n" + (1...160).map { index in
            "\(bodyMarker)第\(index)段。检查封面动画结束后仍能翻页、关闭并恢复同一本书。\n"
        }.joined()
        try Data(text.utf8).write(to: directory.appendingPathComponent("fixture.txt"))
    }

    override func tearDownWithError() throws {
        XCUIApplication().terminate()
        if let directory { try FileManager.default.removeItem(at: directory) }
    }

    @MainActor
    private func launch(grid: Bool, greenReader: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "-no-official-modules", "-onboarding.completed", "YES",
            "-AppleLanguages", "(zh-Hant)", "-AppleLocale", "zh_TW",
            "-yd_source_disclaimer_accepted", "YES", "-reset-explore-home",
            "-shelf-test-dir", directory.path, "-book-source-store-dir", directory.path,
            "-auto-import-epub", directory.appendingPathComponent("fixture.txt").path,
            "-auto-import-title", title, "-bookLayoutIsGrid", grid ? "YES" : "NO",
            "-bookSortOrder", "recentlyRead", "-yd_page_turn_style", "滑動", "-yd_scroll_mode", "NO",
        ]
        if greenReader {
            app.launchArguments += [
                "-AppleInterfaceStyle", "Light", "-yd_reader_theme", "護眼綠", "-lastLightTheme", "護眼綠",
                "-yd_reader_dark_mode", "NO", "-yd_reader_follow_system_theme", "NO", "-yd_appearance_bind_reader_theme", "NO",
            ]
        }
        app.launch()
        return app
    }

    @MainActor
    private func openFromShelf(_ app: XCUIApplication) {
        let tab = app.rootTab("書架")
        XCTAssertTrue(tab.waitForExistence(timeout: 20))
        tab.tap()
        let row = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", title + "，")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 20), app.debugDescription)
        row.tap()
    }

    @MainActor
    private func exerciseAndCloseReader(_ app: XCUIApplication) {
        let page = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", bodyMarker)).firstMatch
        XCTAssertTrue(page.waitForExistence(timeout: 20), "必须真正显示正文。\n\(app.debugDescription)")
        app.swipeLeft()
        XCTAssertTrue(page.waitForExistence(timeout: 5), "翻页后必须仍在阅读器。\n\(app.debugDescription)")
        let back = app.buttons["reader_back_button"]
        if !back.exists {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        }
        XCTAssertTrue(back.waitForExistence(timeout: 5), "动画后不能自动退回书架。\n\(app.debugDescription)")
        XCTAssertTrue(page.exists)
        back.tap()
        XCTAssertTrue(page.waitForNonExistence(timeout: 10))
    }

    @MainActor
    private func verifyRoundTrip(grid: Bool) {
        let app = launch(grid: grid)
        openFromShelf(app)
        exerciseAndCloseReader(app)

        // 同一本已读书先从探索继续阅读，再从书架恢复，覆盖用户报告的入口差异。
        app.rootTab("探索").tap()
        let recent = app.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH 'home.card.library.' AND label BEGINSWITH %@", title)).firstMatch
        XCTAssertTrue(recent.waitForExistence(timeout: 15), app.debugDescription)
        recent.tap()
        exerciseAndCloseReader(app)

        // 搜索页返回后仍能使用同一个书架封面转场，路由注册不能互相拆掉目标。
        app.rootTab("書架").tap()
        let search = app.buttons["bookshelf.search"].firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 10))
        search.tap()
        XCTAssertTrue(app.searchFields.firstMatch.waitForExistence(timeout: 10))
        app.navigationBars.buttons["BackButton"].firstMatch.tap()
        XCTAssertTrue(search.waitForExistence(timeout: 10))

        for _ in 0..<2 {
            openFromShelf(app)
            exerciseAndCloseReader(app)
        }
    }

    @MainActor
    func testResumedReaderPaintsScreenEdgesFromBothEntrances() throws {
        let app = launch(grid: false, greenReader: true)
        openFromShelf(app)
        exerciseAndCloseReader(app)

        app.rootTab("探索").tap()
        let recent = app.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH 'home.card.library.' AND label BEGINSWITH %@", title)).firstMatch
        XCTAssertTrue(recent.waitForExistence(timeout: 15))
        recent.tap()
        let home = try readerPaperColors("explore-reader-green", app: app)
        exerciseAndCloseReader(app)

        openFromShelf(app)
        let shelf = try readerPaperColors("shelf-reader-green", app: app)
        let green = [207, 232, 204]
        for (route, colors) in [("首页", home), ("书架", shelf)] {
            for (area, rgb) in colors {
                XCTAssertTrue(zip(rgb, green).allSatisfy { abs($0.0 - $0.1) <= 8 },
                              "\(route)\(area)：应为护眼绿，实际 RGB \(rgb)")
            }
        }
        exerciseAndCloseReader(app)
    }

    @MainActor
    private func readerPaperColors(_ name: String, app: XCUIApplication) throws -> [(String, [Int])] {
        let page = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", bodyMarker)).firstMatch
        XCTAssertTrue(page.waitForExistence(timeout: 20), "必须实际进入正文。")
        let shot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
        let pixels = try XCTUnwrap(shot.image.cgImage)
        let samplePoints: [(String, Double, Double)] = [("顶部", 0.18, 0.015), ("正文", 0.025, 0.50), ("底部", 0.18, 0.985)]
        return try samplePoints.map { area, x, y in
            // 避开系统状态字、主屏幕指示条和正文，取小块平均色而非比较整张截图。
            let patch = try XCTUnwrap(pixels.cropping(to: CGRect(x: Double(pixels.width) * x, y: Double(pixels.height) * y,
                                                                width: 5, height: 5).integral))
            var rgba = [UInt8](repeating: 0, count: 4)
            let success = rgba.withUnsafeMutableBytes { data -> Bool in
                guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
                      let context = CGContext(data: data.baseAddress, width: 1, height: 1, bitsPerComponent: 8,
                                              bytesPerRow: 4, space: colorSpace,
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
                context.draw(patch, in: CGRect(x: 0, y: 0, width: 1, height: 1))
                return true
            }
            XCTAssertTrue(success, "不能读取模拟器截图颜色。")
            return (area, rgba.prefix(3).map(Int.init))
        }
    }

    @MainActor
    func testReadBookStaysOpenFromShelfListAndExplore() {
        verifyRoundTrip(grid: false)
    }

    @MainActor
    func testReadBookStaysOpenFromShelfGridAndExplore() {
        verifyRoundTrip(grid: true)
    }
}
