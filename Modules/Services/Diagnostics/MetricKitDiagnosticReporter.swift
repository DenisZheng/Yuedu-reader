import Foundation
import MetricKit
import os

/// 接收 MetricKit 崩溃、卡顿、CPU 和写盘诊断，保留完整调用树到本地 DiagnosticLog。
/// iOS 通常在后续启动交付；由用户查看或导出，不连接云端符号化/上报服务。
///
/// Register once at launch via `MetricKitDiagnosticReporter.shared.start()` —
/// currently from `RSSAppNotificationDelegate.application(_:didFinishLaunchingWithOptions:)`,
/// which is an odd home but is the app's only `UIApplicationDelegate` and therefore
/// the earliest reliable hook. The deployment target is iOS 17, well past the iOS 14
/// / 15 floors of every MetricKit diagnostic API used here, so no availability
/// checks are needed. No mutable state → safe as an `@unchecked Sendable` singleton.
///
/// DiagnosticLog 是设备上的诊断副本；模拟器注入只能测试展示，不代替真机交付验证。
final class MetricKitDiagnosticReporter: NSObject, MXMetricManagerSubscriber, @unchecked Sendable {
    static let shared = MetricKitDiagnosticReporter()

    private let log = Logger(subsystem: "com.yuedu.app", category: "MetricKit")

    func start() {
        MXMetricManager.shared.add(self)
        log.notice("⟐ MetricKit subscriber registered")
    }

    /// Crash and hang payloads never arrive in the Simulator — MetricKit only
    /// delivers on device. Without this the whole crash section of the diagnostics
    /// screen would be untestable until a real device crashed, so DEBUG builds can
    /// stage one.
    #if DEBUG
    func injectSampleDiagnosticForTesting() {
        DiagnosticLog.shared.record(
            severity: .fault,
            category: .crash,
            message: "crash: reason=SIMULATED signal=SIGSEGV excType=EXC_BAD_ACCESS",
            detail: "meta={\"simulated\":true}\ncallStack=<injected by injectSampleDiagnosticForTesting()>"
        )
    }
    #endif

    // MARK: - Metrics (daily aggregate). Cheap one-liners; the diagnostics below
    // are the valuable part.

    func didReceive(_ payloads: [MXMetricPayload]) {
        for payload in payloads {
            log.notice("⟐ MXMetricPayload v\(payload.latestApplicationVersion, privacy: .public): \(payload.dictionaryRepresentation().count) metric group(s)")
        }
    }

    // MARK: - Diagnostics (crash / hang / cpu / disk) — the actionable signal.

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        for payload in payloads {
            for d in payload.cpuExceptionDiagnostics ?? [] {
                report(
                    kind: "cpu-exception",
                    summary: "cpu=\(d.totalCPUTime) sampled=\(d.totalSampledTime)",
                    callStack: d.callStackTree, meta: d.metaData
                )
            }
            for d in payload.diskWriteExceptionDiagnostics ?? [] {
                report(
                    kind: "disk-write-exception",
                    summary: "writesCaused=\(d.totalWritesCaused)",
                    callStack: d.callStackTree, meta: d.metaData
                )
            }
            for d in payload.hangDiagnostics ?? [] {
                report(
                    kind: "hang",
                    summary: "hangDuration=\(d.hangDuration)",
                    callStack: d.callStackTree, meta: d.metaData
                )
            }
            for d in payload.crashDiagnostics ?? [] {
                let reason = d.terminationReason ?? "unknown"
                let signal = d.signal?.stringValue ?? "?"
                let excType = d.exceptionType?.stringValue ?? "?"
                report(
                    kind: "crash",
                    summary: "reason=\(reason) signal=\(signal) excType=\(excType)",
                    callStack: d.callStackTree, order: .rootIsLeaf, meta: d.metaData
                )
            }
        }
    }

    private func report(
        kind: String,
        summary: String,
        callStack: MXCallStackTree,
        order: MetricKitCallStack.TreeOrder = .rootIsEntryPoint,
        meta: MXMetaData
    ) {
        let treeData = callStack.jsonRepresentation()
        let stackJSON = String(data: treeData, encoding: .utf8) ?? "<unavailable>"
        let metaJSON = String(data: meta.jsonRepresentation(), encoding: .utf8) ?? "{}"

        let path: MetricKitCallStack?
        do {
            path = try MetricKitCallStack.heaviestPath(fromJSON: treeData, order: order)
        } catch {
            path = nil
            log.error("⟐ MetricKit \(kind, privacy: .public): call stack tree unreadable: \(error.localizedDescription, privacy: .public)")
        }
        let readablePath = path?.summary() ?? "<no call stack>"

        // Full detail to the device log (Console / sysdiagnose).
        log.error("⟐ MetricKit \(kind, privacy: .public): \(summary, privacy: .public)\nmeta=\(metaJSON, privacy: .public)\nheaviest=\(readablePath, privacy: .public)\ncallStack=\(stackJSON, privacy: .public)")

        // The user-visible copy keeps the whole tree: it is the entire value of the report.
        DiagnosticLog.shared.record(
            severity: .fault,
            category: .crash,
            message: "\(kind): \(summary)",
            detail: "meta=\(metaJSON)\nheaviest path (leaf first):\n\(readablePath)\ncallStack=\(stackJSON)"
        )

        CrashContext.breadcrumb("MetricKit \(kind): \(summary)")
    }
}
