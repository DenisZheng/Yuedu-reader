import SwiftUI
import UIKit
import UserNotifications

/// 本地 RSS 通知授权入口。读取状态不弹系统提示，只有按钮操作才申请权限。
struct RSSNotificationSettingsView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL
    @State private var status: UNAuthorizationStatus?
    @State private var requestToken: UUID?
    @State private var errorMessage: String?

    private var isRequesting: Bool { requestToken != nil }

    var body: some View {
        Form {
            Section {
                if let status {
                    ThemedLabeledContent(localized("通知權限"), value: statusTitle(status))
                    if status == .notDetermined {
                        Button {
                            guard requestToken == nil else { return }
                            requestToken = UUID()
                        } label: {
                            SettingsRowLabel(localized("允許訂閱通知"), systemImage: "bell.badge", role: .action)
                        }
                        .disabled(isRequesting)
                        .accessibilityIdentifier("rss_notifications_authorize")
                    } else {
                        Button(action: openSystemSettings) {
                            SettingsRowLabel(localized("開啟系統設定"), systemImage: "gear", role: .action)
                        }
                    }
                } else {
                    ProgressView(localized("載入中…"))
                }
                if isRequesting { ProgressView(localized("載入中…")) }
            } footer: {
                Text(localized("訂閱更新使用本機通知，不需要帳號或遠端推送。"))
                    .dsSectionFooter()
            }
            .interfaceSectionSurface()

            if let errorMessage {
                Section {
                    Text(errorMessage).foregroundStyle(DSColor.destructive)
                }
                .interfaceSectionSurface()
            }
        }
        .navigationTitle(localized("訂閱通知"))
        .toolbarTitleDisplayMode(.inline)
        .themedAppSurface(for: .settings)
        .task(id: scenePhase) {
            guard scenePhase == .active, !isRequesting else { return }
            await refreshStatus()
        }
        .onDisappear { requestToken = nil }
        .task(id: requestToken) {
            guard let token = requestToken else { return }
            errorMessage = nil
            defer {
                // 离开后重新进入的请求有新 token，旧任务不能覆盖它的状态。
                if requestToken == token { requestToken = nil }
            }
            do {
                _ = try await RSSNotificationAuthorization.system.requestIfNeeded()
                await refreshStatus()
            } catch is CancellationError {
                // 离开页面后不再更新视图，也不把取消显示成授权失败。
                return
            } catch {
                guard !Task.isCancelled else { return }
                AppLogger.error("RSS notification authorization failed", error: error)
                errorMessage = localized("無法取得通知權限，請稍後重試。")
            }
        }
    }

    private func refreshStatus() async {
        let current = await RSSNotificationAuthorization.system.currentStatus()
        guard !Task.isCancelled else { return }
        status = current
    }

    private func statusTitle(_ status: UNAuthorizationStatus) -> String {
        switch status {
        case .authorized, .provisional, .ephemeral: localized("通知已允許")
        case .denied: localized("通知已關閉")
        case .notDetermined: localized("通知尚未允許")
        @unknown default: localized("通知狀態未知")
        }
    }

    private func openSystemSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else {
            errorMessage = localized("無法開啟系統設定。")
            return
        }
        openURL(url) { accepted in
            guard !accepted else { return }
            Task { @MainActor in
                errorMessage = localized("無法開啟系統設定。")
            }
        }
    }
}

#Preview {
    NavigationStack { RSSNotificationSettingsView() }
}
