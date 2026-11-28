import SwiftUI

/// 在构造App及其StateObject之前选择测试宿主，避免普通启动触发用户源、通知或云同步。
/// Release与未传参的Debug仍调用原App的标准SwiftUI入口，不另建业务实现路径。
@main
enum ReaderAppMain {
    @MainActor
    static func main() {
        WebDAVRestoreLaunch().run { startApplication() }
    }

    @MainActor
    private static func startApplication() {
        #if DEBUG && targetEnvironment(simulator)
        if RSSPoCTestHost.isEnabled {
            RSSPoCApplication.main()
            return
        }
        #endif
        yuedu_appApp.main()
    }
}

enum RSSPoCTestHost {
    static let isEnabled: Bool = {
        #if DEBUG && targetEnvironment(simulator)
        ProcessInfo.processInfo.arguments.contains("-rss-poc-isolated-host")
        #else
        false
        #endif
    }()
}

#if DEBUG && targetEnvironment(simulator)
private struct RSSPoCApplication: App {
    var body: some Scene {
        WindowGroup {
            if let path = ProcessInfo.processInfo.environment["WEBDAV_RESTORE_FIXTURE"],
               URL(fileURLWithPath: path).lastPathComponent.hasPrefix("WebDAVRestoreUITests-") {
                WebDAVRestoreFixtureHost(root: URL(fileURLWithPath: path))
            } else if ProcessInfo.processInfo.environment["RSS_WEB_DISPLAY_FIXTURE"] == "1" {
                RSSWebDisplayFixtureHost()
            } else if let path = ProcessInfo.processInfo.environment["RSS_IMPORT_UI_FIXTURE"],
               let storage = ProcessInfo.processInfo.environment["RSS_IMPORT_UI_STORAGE"] {
                RSSImportUIFixtureHost(file: URL(fileURLWithPath: path), directory: URL(fileURLWithPath: storage))
            } else if let path = ProcessInfo.processInfo.environment["REPLACE_RULE_IMPORT_UI_STORAGE"],
                      URL(fileURLWithPath: path).lastPathComponent.hasPrefix("ReplaceRuleImportUITests-") {
                ReplaceRuleImportFixtureHost(directory: URL(fileURLWithPath: path))
            } else if ProcessInfo.processInfo.arguments.contains("-rss-audio-host-comparison") {
                RSSAudioHostComparison.probeView()
            } else {
                Color.clear.accessibilityIdentifier("rss-poc-isolated-host")
            }
        }
    }
}

private struct ReplaceRuleImportFixtureHost: View {
    @StateObject private var store: ReplaceRuleStore
    @State private var showRules = false
    @State private var preferenceAudit = ReplaceRuleImportPreferenceAudit()
    @State private var canOpenRules = false
    @State private var completedRuleSessions = 0
    @State private var preferencesUnchanged: Bool?

    init(directory: URL) {
        _store = StateObject(wrappedValue: ReplaceRuleStore(file: directory.appendingPathComponent("replace-rules.json")))
    }

    var body: some View {
        Button(localized("替換規則")) {
            preferencesUnchanged = nil
            showRules = true
        }
        .disabled(!canOpenRules)
        .accessibilityIdentifier("replace-rule-fixture-open")
        .accessibilityValue(preferencesUnchanged.map { $0 ? "unchanged" : "changed" } ?? "pending")
        .task(id: completedRuleSessions) {
            let unchanged: Bool?
            if completedRuleSessions == 0 {
                await preferenceAudit.captureBaseline()
                unchanged = nil
            } else {
                unchanged = await preferenceAudit.matchesBaseline()
            }
            guard !Task.isCancelled else { return }
            preferencesUnchanged = unchanged
            canOpenRules = true
        }
        .sheet(isPresented: $showRules, onDismiss: {
            canOpenRules = false
            completedRuleSessions += 1
        }) { ReplaceRuleListView(store: store) }
        .environment(\.usesUserAppearance, false)
    }
}

/// 仅在 Debug 模拟器测试读取和比较；偏好快照不离开这个 actor，页面只接收布尔值。
private actor ReplaceRuleImportPreferenceAudit {
    private var baseline: NSDictionary?

    func captureBaseline() {
        if baseline == nil { baseline = snapshot() }
    }

    func matchesBaseline() -> Bool {
        guard let baseline else { return false }
        return baseline.isEqual(snapshot())
    }

    private func snapshot() -> NSDictionary {
        dispatchPrecondition(condition: .notOnQueue(.main))
        guard let domain = Bundle.main.bundleIdentifier else { preconditionFailure("缺少测试宿主标识") }
        return (UserDefaults.standard.persistentDomain(forName: domain) ?? [:]) as NSDictionary
    }
}
#endif
