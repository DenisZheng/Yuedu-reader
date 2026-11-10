import Testing
import Foundation
@testable import yuedu_app

@Suite("Root tab customization")
struct RootTabCustomizationTests {
    @Test("settings tab is always restored")
    func settingsTabIsAlwaysRestored() {
        let ids = GlobalSettings.sanitizedRootTabVisibleIDs([
            RootTabItem.bookshelf.rawValue
        ])

        #expect(ids.contains(RootTabItem.bookshelf.rawValue))
        #expect(ids.contains(RootTabItem.settings.rawValue))
    }

    @Test("at least one content tab remains visible")
    func atLeastOneContentTabRemainsVisible() {
        // 資源庫、訂閱都隱藏：未列出的後加Tab會被顯示。
        let ids = GlobalSettings.sanitizedRootTabVisibleIDs([
            RootTabItem.settings.rawValue,
            RootTabItem.library.hiddenMarker,
            RootTabItem.rss.hiddenMarker
        ])

        #expect(ids.contains(RootTabItem.bookshelf.rawValue))
        #expect(ids.contains(RootTabItem.settings.rawValue))
    }

    @Test("unknown tab ids and the retired 搜索 tab are dropped; order is stable")
    func unknownTabIDsAreDroppedAndOrderIsStable() {
        let ids = GlobalSettings.sanitizedRootTabVisibleIDs([
            "unknown",
            RootTabItem.search.rawValue,
            RootTabItem.library.rawValue,
            RootTabItem.bookshelf.rawValue,
            RootTabItem.settings.rawValue,
            RootTabItem.rss.hiddenMarker
        ])

        #expect(ids == [
            RootTabItem.bookshelf.rawValue,
            RootTabItem.library.rawValue,
            RootTabItem.settings.rawValue,
            RootTabItem.rss.hiddenMarker
        ])
    }

    @Test("Fork五Tab：探索｜書架｜訂閱｜資源庫｜設定；搜索不再是Tab")
    func tabOrder() {
        #expect(RootTabItem.tabs == [.explore, .bookshelf, .rss, .library, .settings])
        #expect(!RootTabItem.tabs.contains(.search))
        #expect(GlobalSettings.defaultRootTabVisibleIDs == ["explore", "bookshelf", "rss", "library", "settings"])
        #expect(RootTabItem.rss.titleKey == "訂閱")
    }

    @Test("早期Fork清單（含搜索、無訂閱）升級後顯示訂閱、去掉搜索")
    func oldForkListGainsSubscriptions() {
        let saved = GlobalSettings.sanitizedRootTabVisibleIDs(["explore", "bookshelf", "library", "settings", "search"])
        #expect(saved == ["explore", "bookshelf", "rss", "library", "settings"])
    }

    @Test("Hiding 資源庫 or 訂閱 is kept; showing again restores the position")
    @MainActor
    func hidingLaterTabsSticks() {
        for tab in [RootTabItem.library, .rss] {
            let ids = GlobalSettings.sanitizedRootTabVisibleIDs(
                GlobalSettings.updatedRootTabVisibleIDs(GlobalSettings.defaultRootTabVisibleIDs, setting: tab, visible: false))
            #expect(!ids.contains(tab.rawValue))
            #expect(ids.contains(tab.hiddenMarker))
            #expect(GlobalSettings.sanitizedRootTabVisibleIDs(ids) == ids, "stable once hidden")
            let shown = GlobalSettings.sanitizedRootTabVisibleIDs(
                GlobalSettings.updatedRootTabVisibleIDs(ids, setting: tab, visible: true))
            #expect(shown == GlobalSettings.defaultRootTabVisibleIDs)
        }
    }

    @Test("A custom 搜索 tab icon stays stored: its tab still decodes though it is not drawn")
    func retiredSearchIconAssetKept() {
        let asset = RootTabIconAsset(tabID: "search", slotRawValue: "light", fileName: "search.png",
                                     originalFileName: "search.png", addedAt: Date())
        #expect(asset.tab == .search)
        #expect(!RootTabItem.tabs.contains(.search))
    }

    @Test("tab icon size is clamped")
    func tabIconSizeIsClamped() {
        #expect(RootTabIconRenderer.sanitizedIconSize(10) == 22)
        #expect(RootTabIconRenderer.sanitizedIconSize(28) == 28)
        #expect(RootTabIconRenderer.sanitizedIconSize(80) == 36)
    }

    @Test("zero tab icon size keeps Apple's system default")
    func zeroTabIconSizeKeepsSystemDefault() {
        #expect(GlobalSettings.sanitizedRootTabIconSize(0) == 0)
        #expect(GlobalSettings.sanitizedRootTabIconSize(-8) == 0)
        #expect(GlobalSettings.sanitizedRootTabIconSize(10) == 22)
    }
}
