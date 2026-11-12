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
            } else {
                Color.clear.accessibilityIdentifier("rss-poc-isolated-host")
            }
        }
    }
}
#endif
