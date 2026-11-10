import XCTest

extension XCUIApplication {
    /// Fork 五Tab后搜索不再是Tab：从探索（第一个Tab）的放大镜进入同一个搜索页。
    @MainActor
    func openSearchPage(timeout: TimeInterval = 30, file: StaticString = #filePath, line: UInt = #line) {
        let explore = rootTab("探索").exists ? rootTab("探索") : rootTab("Explore")
        XCTAssertTrue(explore.waitForExistence(timeout: timeout), debugDescription, file: file, line: line)
        explore.tap()
        let button = buttons["explore.search"].firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: timeout), debugDescription, file: file, line: line)
        button.tap()
    }
}

extension XCUIApplication {
    /// iPadOS 27 adapts the root tabs to a top segmented control; it is exposed as ordinary buttons,
    /// not `XCUIElementTypeTabBar`. iPhone continues to expose `tabBars.buttons`.
    @MainActor
    func rootTab(_ title: String) -> XCUIElement {
        if tabBars.firstMatch.exists { return tabBars.buttons[title].firstMatch }
        // 排除推入页的同名返回按钮，不能把“返回资源库”当作 Tab 可达的证据。
        return buttons.matching(NSPredicate(format: "label == %@ AND identifier != 'BackButton'", title)).firstMatch
    }

    @MainActor
    func rootTabLabels(_ expected: [String]) -> [String] {
        if tabBars.firstMatch.exists { return tabBars.buttons.allElementsBoundByIndex.map(\.label) }
        let existing = expected.compactMap { title -> (String, CGFloat)? in
            let item = rootTab(title)
            return item.exists ? (title, item.frame.minX) : nil
        }
        return existing.sorted { $0.1 < $1.1 }.map(\.0)
    }
}
