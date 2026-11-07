import UserNotifications

/// 系统权限仍由 UserNotifications 拥有；这里只约束“读取不弹窗，用户操作才请求”。
/// 注入两个系统操作用于无弹窗测试，不缓存或持久化第二份权限状态。
struct RSSNotificationAuthorization: Sendable {
    static let system = Self(
        status: { await UNUserNotificationCenter.current().notificationSettings().authorizationStatus },
        request: { try await UNUserNotificationCenter.current().requestAuthorization(options: [.badge, .sound, .alert]) }
    )

    private let status: @Sendable () async -> UNAuthorizationStatus
    private let request: @Sendable () async throws -> Bool

    init(
        status: @escaping @Sendable () async -> UNAuthorizationStatus,
        request: @escaping @Sendable () async throws -> Bool
    ) {
        self.status = status
        self.request = request
    }

    func currentStatus() async -> UNAuthorizationStatus { await status() }

    /// 仅由用户的允许通知按钮调用；已拒绝时不能反复弹窗，交给系统设置管理。
    func requestIfNeeded() async throws -> Bool {
        try Task.checkCancellation()
        let current = await status()
        try Task.checkCancellation()
        switch current {
        case .notDetermined:
            let granted = try await request()
            try Task.checkCancellation()
            return granted
        case .authorized, .provisional, .ephemeral:
            return true
        case .denied:
            return false
        @unknown default:
            return false
        }
    }
}
