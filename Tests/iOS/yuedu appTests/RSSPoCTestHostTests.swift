import Testing
import UserNotifications
@testable import yuedu_app

/// 仅PoC scheme运行：普通App回归继续验证真实启动，不能拿轻量宿主代替冷启动验收。
@Suite("RSS PoC isolated host", .enabled(if: RSSPoCTestHost.isEnabled))
@MainActor
struct RSSPoCTestHostTests {
    @Test("专用宿主已启用且没有安装通知/后台刷新启动链路")
    func isolatedBootstrap() {
        #expect(RSSPoCTestHost.isEnabled)
        #expect(UNUserNotificationCenter.current().delegate == nil)
    }
}
