import Foundation
import os

/// 诊断的本地入口；不初始化 SDK、不创建网络请求。保留调用接口，避免改动阅读热路径。
/// 上下文只存在内存中，错误和活动栈交给现有 DiagnosticLog 合并落盘。
enum CrashContext {
    private static let context = LocalDiagnosticContext(log: .shared)

    static func breadcrumb(_ message: String) { context.breadcrumb(message) }
    static func setKey(_ key: String, _ value: String) { context.setKey(key, value) }
    static func setKey(_ key: String, _ value: Int) { context.setKey(key, String(value)) }
    static func setKey(_ key: String, _ value: Bool) { context.setKey(key, String(value)) }

    static func recordNonFatal(domain: String, code: Int = 0, message: String, extra: [String: String] = [:]) {
        context.recordNonFatal(domain: domain, code: code, message: message, extra: extra)
    }

    static func recordActivityIssue(name: String, reason: String, activities: [String]) {
        context.recordActivityIssue(name: name, reason: reason, activities: activities)
    }
}

/// 实例仅用于隔离测试日志；生产只有 CrashContext 持有的一份，不建立第二套日志存储。
/// 锁只保护有界内存上下文，格式化与日志写入均在锁外执行。
final class LocalDiagnosticContext: @unchecked Sendable {
    static let keyLimit = 64
    static let valueLimit = 1024
    private static let messageLimit = 4096

    private let lock = NSLock()
    private var values: [String: String] = [:]
    private var omittedKeys = false
    private let log: DiagnosticLog
    private let systemLog = Logger(subsystem: "com.yuedu.app", category: "CrashContext")

    init(log: DiagnosticLog) { self.log = log }

    func setKey(_ key: String, _ value: String) {
        let safeKey = Self.sanitized(key, limit: 128)
        let safeValue = Self.sanitized(DiagnosticRedactor.redactField(value, key: key), limit: Self.valueLimit)
        lock.withLock {
            guard values[safeKey] != nil || values.count < Self.keyLimit else {
                omittedKeys = true
                return
            }
            if values[safeKey] != safeValue { values[safeKey] = safeValue }
        }
    }

    func snapshot() -> [String: String] { lock.withLock { values } }

    func breadcrumb(_ message: String) {
        let safe = Self.sanitized(message, limit: Self.messageLimit)
        systemLog.debug("🍞 \(safe, privacy: .public)")
        log.record(severity: .info, category: .general, message: "🍞 \(safe)")
    }

    func recordNonFatal(domain: String, code: Int = 0, message: String, extra: [String: String] = [:]) {
        record(
            message: "non-fatal [\(Self.sanitized(domain, limit: 128)):\(code)] \(Self.sanitized(message, limit: Self.messageLimit))",
            category: .general,
            detail: extra.prefix(Self.keyLimit).map { key, value in
                "\(Self.sanitized(key, limit: 128))=\(Self.sanitized(DiagnosticRedactor.redactField(value, key: key), limit: Self.valueLimit))"
            }.sorted().joined(separator: "\n") + (extra.count > Self.keyLimit ? "\n[extra fields truncated]" : "")
        )
    }

    func recordActivityIssue(name: String, reason: String, activities: [String]) {
        let stack = activities.isEmpty ? "(no instrumented span)" : activities.suffix(32).reversed()
            .map { Self.sanitized($0, limit: Self.valueLimit) }.joined(separator: "\n")
        record(
            message: "\(Self.sanitized(name, limit: 128)): \(Self.sanitized(reason, limit: Self.messageLimit))",
            category: .crash,
            detail: "activities (innermost first):\n\(stack)" + (activities.count > 32 ? "\n[activities truncated]" : "")
        )
    }

    private func record(message: String, category: DiagnosticCategory, detail: String) {
        let (current, truncated) = lock.withLock { (values, omittedKeys) }
        var sections: [String] = []
        if !current.isEmpty {
            sections.append("context:\n" + current.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: "\n"))
        }
        if truncated { sections.append("[context keys truncated]") }
        if !detail.isEmpty { sections.append(detail) }
        systemLog.error("⚠️ \(message, privacy: .public)")
        log.record(severity: .error, category: category, message: message, detail: sections.isEmpty ? nil : sections.joined(separator: "\n"))
    }

    private static func sanitized(_ value: String, limit: Int) -> String {
        // 不截取原始凭据的前半段；超限整段省略，避免截断后破坏脱敏模式。
        guard value.utf8.prefix(limit + 1).count <= limit else { return "<omitted: size limit>" }
        let redacted = DiagnosticRedactor.redact(value)
        return redacted.utf8.prefix(limit + 1).count <= limit ? redacted : "<omitted: size limit>"
    }
}
