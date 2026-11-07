import Combine
import XCTest
@testable import yuedu_app

@MainActor
final class ReaderSettingsPublicationTests: XCTestCase {
    func testChangedThemeAppliesOnceAndIdenticalThemeDoesNotRepublish() throws {
        let original = ReaderPreferences.current()
        defer { original.apply() }
        original.apply()
        let theme = try XCTUnwrap(ReaderTheme.allCases.first { $0.rawValue != original.theme })
        var next = original
        next.theme = theme.rawValue
        var themes: [ReaderTheme] = []
        let token = ReaderConfig.shared.$theme.dropFirst().sink { themes.append($0) }
        next.apply()
        next.apply()
        XCTAssertEqual(ReaderTheme.loadPersisted(), theme)
        XCTAssertEqual(ReaderConfig.shared.theme, theme)
        XCTAssertEqual(themes, [theme])
        withExtendedLifetime(token) {}
    }

    func testIdenticalPreferencesAndConfigPublishNothing() {
        let settings = GlobalSettings.shared
        let preferences = ReaderPreferences.current()
        preferences.apply()
        var configPublications = 0
        let settingsRecorder = ObservationRecorder { ReaderPreferences.current(settings: settings) }
        let configToken = ReaderConfig.shared.objectWillChange.sink { configPublications += 1 }
        preferences.apply()
        ReaderConfig.shared.syncFromGlobalSettings()
        XCTAssertEqual(settingsRecorder.changeCount, 0)
        XCTAssertEqual(configPublications, 0)
        settingsRecorder.cancel()
        withExtendedLifetime(configToken) {}
    }

    func testIdenticalBubbleSyncPublishesNothing() {
        let settings = GlobalSettings.shared
        settings.applyCommentBubbleSync(styles: settings.commentBubbleCustomStyles)
        let recorder = ObservationRecorder { settings.commentBubbleCustomStyles }
        settings.applyCommentBubbleSync(styles: settings.commentBubbleCustomStyles)
        XCTAssertEqual(recorder.changeCount, 0)
        recorder.cancel()
    }

    func testRemoteChangeSupersedesPendingLocalWritebackWithoutEcho() async {
        let settings = GlobalSettings.shared
        let original = ReaderPreferences.current()
        defer { original.apply() }
        original.apply()
        // This edit has already entered the existing slider debounce when sync arrives.
        ReaderConfig.shared.fontSize = CGFloat(original.readerFontSize + 1)
        var remote = original
        remote.readerFontSize += 2
        remote.readerHeaderTopPadding = (original.readerHeaderTopPadding ?? 0) + 5
        let fontValues = ObservationRecorder { settings.readerFontSize }
        let recorded = expectation(description: "远端字号应用后的观察值")
        fontValues.onRecord = { value in
            if value == remote.readerFontSize { recorded.fulfill() }
        }
        remote.apply()
        await fulfillment(of: [recorded], timeout: 2)
        fontValues.onRecord = nil
        XCTAssertEqual(fontValues.values, [remote.readerFontSize])
        XCTAssertEqual(ReaderConfig.shared.fontSize, CGFloat(remote.readerFontSize))
        XCTAssertEqual(settings.readerHeaderTopPadding, remote.readerHeaderTopPadding)
        let echo = ObservationRecorder { ReaderPreferences.current(settings: settings) }
        // 覆盖既有120ms防抖窗口：断言没有回写事件，不靠延时猜测应用已稳定。
        let noEcho = expectation(description: "远端应用不能触发本地回写")
        noEcho.isInverted = true
        echo.onRecord = { _ in noEcho.fulfill() }
        await fulfillment(of: [noEcho], timeout: 0.3)
        XCTAssertEqual(echo.changeCount, 0, "remote sync must not echo after the slider debounce")
        XCTAssertEqual(fontValues.values, [remote.readerFontSize])
        echo.cancel()
        fontValues.cancel()
    }

    func testUserEditStillWritesBackAfterRemoteSync() {
        let settings = GlobalSettings.shared
        let original = ReaderPreferences.current()
        defer { original.apply() }
        original.apply()
        let expected = original.readerFontSize + 1
        ReaderConfig.shared.fontSize = CGFloat(expected)
        // The write-back is debounced; run the main loop until it lands, up to 2 s.
        let deadline = Date(timeIntervalSinceNow: 2)
        while settings.readerFontSize != expected, Date() < deadline {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02))
        }
        XCTAssertEqual(settings.readerFontSize, expected)
    }

    func testBubbleDeletionRepairsSelectionAndPreservesSyncClock() {
        let settings = GlobalSettings.shared
        let styles = settings.commentBubbleCustomStyles
        let selected = settings.commentBubbleSelectedCustomStyleID
        let mode = settings.commentBubblePresetMode
        let clock = settings.commentBubbleSelectionSyncClock
        defer {
            settings.applyCommentBubbleSync(styles: styles)
            settings.applyCommentBubbleSync(selection: selected)
            settings.commentBubblePresetMode = mode
        }
        let style = ReaderCommentBubbleCustomStyle(name: "Publication test", svg: "<svg/>")
        settings.applyCommentBubbleSync(styles: styles + [style])
        settings.applyCommentBubbleSync(selection: style.id)
        let recorder = ObservationRecorder {
            (settings.commentBubbleSelectedCustomStyleID, settings.commentBubblePresetMode,
             settings.commentBubbleSelectionSyncClock, settings.commentBubbleCustomStyles)
        }
        settings.applyCommentBubbleSync(selection: style.id)
        XCTAssertEqual(recorder.changeCount, 0)
        recorder.cancel()
        settings.applyCommentBubbleSync(styles: styles)
        XCTAssertNil(settings.commentBubbleSelectedCustomStyleID)
        XCTAssertEqual(settings.commentBubblePresetMode, .builtin)
        XCTAssertEqual(settings.commentBubbleSelectionSyncClock, clock)
    }
}
