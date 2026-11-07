import SwiftUI
import UIKit

struct SettingsView: View {
    @EnvironmentObject var store: BookStore

    @Environment(\.openURL) private var openURL
    @Environment(\.colorScheme) private var colorScheme
    @Bindable private var gs = GlobalSettings.shared
    /// 來源配置管理, 模組 and its pages, and 聚合設定 push `ExploreNavigationRoute` values. A page
    /// opened by `navigationDestination(isPresented:)` on a stack without a path is pushed again on
    /// top of a value pushed after it (模組 reappeared over 測試倉庫), so each is a value.
    @State private var path = NavigationPath()
    /// 模組's 新增模組 (its toolbar), presented from this root: the one place a module is added.
    @StateObject private var moduleFlow = RuleModuleAddFlow()
    @State private var showDownloadManager = false
    @State private var showReplaceRules = false
    @State private var showBackupSync = false
    @State private var showCacheManagement = false
    @State private var showLanServer = false
    @State private var showTTSSettings = false
    @State private var showNetworkSettings = false
    @State private var showAISettings = false
    #if DEBUG
    @State private var didAutoOpenDiagnostics = false
    #endif
    private enum LocalRoute: Hashable {
        case diagnostics, rssNotifications
    }

    private var appLanguageFooter: String {
        // The name iOS Settings lists the app under: the display name (閱讀), not the bundle name.
        let appName = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "App"
        let template = localized("跟隨系統語言。可在「設定 → %@ → 語言」單獨設定")
        return String(format: template, appName)
    }

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
    }

    private var appearanceThemeName: String {
        gs.appearanceTheme(
            for: colorScheme
        ).localizedName
    }

    var body: some View {
        NavigationStack(path: $path) {
                Form {
                    // Grouped by what each is for (maintainer, 2026-10-27): 一般, 資源, 閱讀, 資料, 支援.

                    // ── 一般 ──
                    // 書架顯示 (每列欄數, 預設封面) lives in 外觀主題's 介面 since 2026-09-29.
                    Section {
                        NavigationLink {
                            AppearanceThemeView()
                        } label: {
                            HStack {
                                Label(localized("外觀主題"), systemImage: "paintpalette.fill")
                                    .foregroundColor(DSColor.textPrimary)
                                    .labelStyle(IconConsistentLabelStyle())
                                Spacer(minLength: 12)
                                Text(appearanceThemeName)
                                    .font(DSFont.caption)
                                    .foregroundColor(DSColor.textSecondary)
                            }
                        }
                        .rootTabTitleScrollAnchor()

                        DSSettingsRow(
                            icon: "globe",
                            title: localized("語言"),
                            action: {
                                if let url = URL(string: UIApplication.openSettingsURLString) {
                                    openURL(url)
                                }
                            }
                        )
                        NavigationLink(value: LocalRoute.rssNotifications) {
                            Label(localized("訂閱通知"), systemImage: "bell")
                                .foregroundColor(DSColor.textPrimary)
                                .labelStyle(IconConsistentLabelStyle())
                        }
                        .accessibilityIdentifier("settings_rss_notifications")
                    } header: {
                        Text(localized("設定分組：一般"))
                            .foregroundStyle(DSColor.textSecondary)
                    } footer: {
                        Text(appLanguageFooter)
                            .dsSectionFooter()
                    }
                    .interfaceSectionSurface()

                    // ── 資源 ──
                    // Where every source is added (maintainer, 2026-10-27: 「把添加資源的入口都放在設置頁」):
                    // each kind's page, whose toolbar adds one. 資源庫 lists what is there. RSS 訂閱
                    // stays in 資源庫, a page to read rather than a setting (the maintainer's choice).
                    Section {
                        DSSettingsRow(
                            icon: "books.vertical.fill",
                            title: localized("來源配置管理"),
                            action: { path.append(ExploreNavigationRoute.sourceManager) }
                        )
                        .accessibilityIdentifier("settings_sources")

                        // 模組 (M6), here since the maintainer moved it from 資源庫's •••
                        // (2026-10-17: 「模組設定頁在設置好了」).
                        DSSettingsRow(
                            icon: "puzzlepiece.extension.fill",
                            title: localized("模組"),
                            action: { path.append(ExploreNavigationRoute.moduleManager) }
                        )
                        .accessibilityIdentifier("settings_modules")

                        NavigationLink {
                            RemoteLibrarySettingsView()
                        } label: {
                            Label(localized("遠端書庫"), systemImage: "server.rack")
                                .foregroundColor(DSColor.textPrimary)
                                .labelStyle(IconConsistentLabelStyle())
                        }
                        .accessibilityIdentifier("settings_remote_libraries")

                        // 聚合設定 (unified library 5d-3d, decision 21): here only, as Emby's
                        // aggregation settings sit in its user settings.
                        DSSettingsRow(
                            icon: "square.stack.3d.up.fill",
                            title: localized("聚合設定"),
                            action: { path.append(ExploreNavigationRoute.aggregationSettings) }
                        )
                        .accessibilityIdentifier("settings_aggregation")

                        DSSettingsRow(
                            icon: "network",
                            title: localized("網路設定"),
                            action: { showNetworkSettings = true }
                        )
                    } header: {
                        Text(localized("設定分組：資源"))
                            .foregroundStyle(DSColor.textSecondary)
                    }
                    .interfaceSectionSurface()

                    // ── 閱讀 ──
                    Section {
                        DSSettingsRow(
                            icon: "waveform",
                            title: localized("語音朗讀設定"),
                            action: { showTTSSettings = true }
                        )

                        DSSettingsRow(
                            icon: "sparkles",
                            // Named for what it is — the reader's panel is also called
                            // 「AI 助手」, and someone looking for 人物卡 went here first.
                            title: localized("AI 助手設定"),
                            detail: aiAssistantDetail,
                            isLocked: false,
                            action: {
                                showAISettings = true
                            }
                        )

                        DSSettingsRow(
                            icon: "text.magnifyingglass",
                            title: localized("替換規則"),
                            action: { showReplaceRules = true }
                        )

                        // FB-139: pushed, not a sheet like 替換規則 — its file importer needs a
                        // first-level presenter on iOS 17.
                        NavigationLink {
                            TXTTocRuleListView()
                        } label: {
                            Label(localized("TXT 分章規則"), systemImage: "list.number")
                                .foregroundColor(DSColor.textPrimary)
                                .labelStyle(IconConsistentLabelStyle())
                        }
                        .accessibilityIdentifier("settings_txt_toc_rules")
                    } header: {
                        Text(localized("設定分組：閱讀"))
                            .foregroundStyle(DSColor.textSecondary)
                    }
                    .interfaceSectionSurface()

                    // ── 資料 ──
                    Section {
                        DSSettingsRow(
                            icon: "arrow.triangle.2.circlepath.icloud",
                            title: localized("備份與同步"),
                            detail: localized("iCloud、WebDAV"),
                            action: { showBackupSync = true }
                        )

                        DSSettingsRow(
                            icon: "arrow.down.circle.fill",
                            title: localized("下載管理"),
                            detail: String(format: localized("%d 本"), downloadedBooksCount),
                            action: { showDownloadManager = true }
                        )

                        DSSettingsRow(
                            icon: "externaldrive.fill",
                            title: localized("快取管理"),
                            action: { showCacheManagement = true }
                        )

                        DSSettingsRow(
                            icon: "wifi",
                            title: localized("局域網服務"),
                            action: { showLanServer = true }
                        )
                    } header: {
                        Text(localized("設定分組：資料"))
                            .foregroundStyle(DSColor.textSecondary)
                    }
                    .interfaceSectionSurface()

                    // ── 支援 ──
                    Section {
                        NavigationLink(value: LocalRoute.diagnostics) {
                            Label(localized("診斷紀錄"), systemImage: "doc.text.magnifyingglass")
                                .foregroundColor(DSColor.textPrimary)
                                .labelStyle(IconConsistentLabelStyle())
                        }
                        .accessibilityIdentifier("settings_diagnostics")

                        NavigationLink {
                            AboutSupportView(appVersion: appVersion)
                        } label: {
                            HStack {
                                Label(localized("關於"), systemImage: "info.circle.fill")
                                    .foregroundColor(DSColor.textPrimary)
                                    .labelStyle(IconConsistentLabelStyle())
                                Spacer(minLength: 12)
                                Text(appVersion)
                                    .font(DSFont.caption)
                                    .foregroundColor(DSColor.textSecondary)
                            }
                        }
                    } header: {
                        Text(localized("設定分組：支援"))
                            .foregroundStyle(DSColor.textSecondary)
                    }
                    .interfaceSectionSurface()
                }
            .softScrollEdges()
            .themedAppSurface(for: .settings)
            .rootTabTitle(localized("設定"), onScroll: .minimizesBar)
            // Back from 外觀主題: its 淺色／深色 preview ends here.
            .onAppear { gs.endAppearanceSlotPreview() }
            // 來源配置管理, 模組 and 聚合設定 are `ExploreNavigationRoute` values, as are 模組's own
            // pages (官方模組, 匯入的模組, a repository, a module). None of them opens a source's
            // page, the one route that goes out to the browser, so this stack has no browser to open.
            .exploreRouteDestinations(openBrowser: { _ in })
            .navigationDestination(for: LocalRoute.self) { route in
                switch route {
                case .diagnostics: DiagnosticsView()
                case .rssNotifications: RSSNotificationSettingsView()
                }
            }
            #if DEBUG
            // 调试启动可直达本地诊断页；Release 不包含该入口。
            .onAppear {
                if !didAutoOpenDiagnostics, ProcessInfo.processInfo.arguments.contains("-open-diagnostics") {
                    didAutoOpenDiagnostics = true
                    path.append(LocalRoute.diagnostics)
                }
            }
            #endif
            .sheet(isPresented: $showDownloadManager) {
                DownloadManagementView()
                    .environmentObject(store)
            }
            .sheet(isPresented: $showNetworkSettings) {
                NetworkSettingsView()
            }
            .sheet(isPresented: $showAISettings) {
                AISettingsView()
            }
            .sheet(isPresented: $showReplaceRules) {
                ReplaceRuleListView()
            }
            .sheet(isPresented: $showBackupSync) {
                BackupSyncView()
            }
            .sheet(isPresented: $showCacheManagement) {
                CacheManagementView(service: CacheManagementService(coverOwner: store))
            }
            .sheet(isPresented: $showLanServer) {
                LanServerView().environmentObject(store)
            }
            .sheet(isPresented: $showTTSSettings) {
                TTSSettingsView()
            }
            // The only file importer on this root (one per view: SwiftUI presents just one).
            .ruleModuleAddFlow(moduleFlow)
        }
        .environment(\.ruleModuleAddFlow, moduleFlow)
    }

    private var downloadedBooksCount: Int {
        store.books.filter { $0.isOnline && $0.offlineDownloadState == .available }.count
    }

    /// Says whether AI is usable at a glance. A reader who has not set it up should not have
    /// to open the screen to find that out.
    private var aiAssistantDetail: String {
        AIProviderStore.shared.hasConfiguredProfile ? localized("已啟用") : localized("未設定")
    }


}

private struct AboutSupportView: View {
    @Environment(OnboardingState.self) private var onboarding: OnboardingState?
    let appVersion: String

    var body: some View {
        List {
            Section {
                ThemedLabeledContent(localized("版本"), value: appVersion)
                if let onboarding {
                    Button {
                        withAnimation(DSAnimation.standard) { onboarding.replay() }
                    } label: {
                        SettingsRowLabel(localized("新手導覽"), systemImage: "hand.wave", role: .action)
                    }
                    .accessibilityIdentifier("about.onboarding")
                }
            } footer: {
                Text(localized("本機功能不收費；AI 等外部服務需自行設定。"))
                    .dsSectionFooter()
            }
            .interfaceSectionSurface()

            Section {
                if let url = URL(string: "https://github.com/CHANG-JUI-LIN/Yuedu-reader") {
                    Link(destination: url) {
                        SettingsRowLabel(localized("上游專案與授權"), systemImage: "chevron.left.forwardslash.chevron.right", role: .action)
                    }
                }
            } footer: {
                Text(localized("本 App 是獨立 Fork，不使用上游帳號、會員或聯絡管道。"))
                    .dsSectionFooter()
            }
            .interfaceSectionSurface()
        }
        .navigationTitle(localized("關於"))
        .toolbarTitleDisplayMode(.inline)
        .themedAppSurface(for: .settings)
    }
}

#Preview {
    SettingsView()
        .environmentObject(BookStore())

}
