import CoreFoundation
import SwiftUI

/// 入口保持同步：后台恢复完成后，从普通主RunLoop回调启动UIKit，不把App.main放进未返回的MainActor任务。
/// CFRunLoopPerformBlock/WakeUp允许跨线程投递；引用不可变，回调只在明确的主RunLoop运行。
final class WebDAVRestoreLaunch: @unchecked Sendable {
    private let loop: CFRunLoop
    private let source: CFRunLoopSource

    @MainActor init() {
        loop = CFRunLoopGetMain()
        var context = CFRunLoopSourceContext()
        context.perform = { _ in } // 仅保活RunLoop，后台完成后移除，不执行轮询。
        source = CFRunLoopSourceCreate(kCFAllocatorDefault, 0, &context)
        CFRunLoopAddSource(loop, source, .defaultMode)
    }

    @MainActor
    func run(start: @escaping @MainActor @Sendable () -> Void) {
        Task.detached { [self] in
            let succeeded: Bool
            do { try await WebDAVRestoreBootstrap.recoverBeforeLaunch(); succeeded = true }
            catch {
                AppLogger.sync("WebDAV startup recovery failed code=\((error as NSError).code)", level: .fault)
                succeeded = false
            }
            CFRunLoopPerformBlock(loop, CFRunLoopMode.defaultMode.rawValue) { [self] in
                MainActor.assumeIsolated {
                    CFRunLoopRemoveSource(loop, source, .defaultMode)
                    if succeeded { start() }
                    else { WebDAVRecoveryApplication.main() }
                    CFRunLoopStop(loop)
                }
            }
            CFRunLoopWakeUp(loop)
        }
        CFRunLoopRun()
    }
}

private struct WebDAVRecoveryApplication: App {
    var body: some Scene { WindowGroup { WebDAVRecoveryFailureView() } }
}

private struct WebDAVRecoveryFailureView: View {
    @State private var retrying = false
    @State private var recovered = false

    var body: some View {
        ContentUnavailableView {
            Label(localized("本機資料復原"), systemImage: "externaldrive.badge.exclamationmark")
        } description: {
            Text(recovered ? localized("原始資料已復原，請關閉並重新開啟 App。")
                 : localized("還原失敗，原始資料副本已保留，請勿繼續同步"))
        } actions: {
            if retrying { ProgressView() }
            else if !recovered {
                Button(localized("重試")) { retrying = true }
                    .accessibilityIdentifier("webdav.recovery.retry")
            }
        }
        .task(id: retrying) {
            guard retrying else { return }
            defer { retrying = false }
            do { try await WebDAVRestoreBootstrap.recoverBeforeLaunch(); recovered = true }
            catch { AppLogger.sync("WebDAV startup recovery retry failed code=\((error as NSError).code)", level: .fault) }
        }
    }
}

#Preview("Recovery failed") { WebDAVRecoveryFailureView() }
