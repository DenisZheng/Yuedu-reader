import Foundation
import Testing
@testable import yuedu_app

@Suite("本地诊断上下文")
struct LocalDiagnosticContextTests {
    private func withLog(_ body: (LocalDiagnosticContext, DiagnosticLog) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("local-diagnostics-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let log = DiagnosticLog(directory: directory, verboseOverride: false)
        defer {
            log.flush(wait: true)
            do {
                try FileManager.default.removeItem(at: directory)
            } catch {
                Issue.record(error, "清理测试自己的诊断目录失败")
            }
        }
        try body(LocalDiagnosticContext(log: log), log)
    }

    @Test("没有 Firebase 时错误和最新上下文仍写入本地日志")
    func nonFatalPersistsContext() throws {
        try withLog { context, log in
            context.setKey("reader_mode", "paged")
            context.setKey("reader_mode", "scroll")
            context.setKey("chapter", "8")
            context.recordNonFatal(domain: "RSS", code: 42, message: "parse failed", extra: ["stage": "content"])

            let entries = log.snapshot()
            let entry = try #require(entries.first)
            #expect(entries.count == 1)
            #expect(entry.severity == .error)
            #expect(entry.message.contains("RSS:42"))
            #expect(entry.detail?.contains("reader_mode=scroll") == true)
            #expect(entry.detail?.contains("reader_mode=paged") == false)
            #expect(entry.detail?.contains("chapter=8") == true)
            #expect(entry.detail?.contains("stage=content") == true)
        }
    }

    @Test("上下文更新不写盘，重复赋值不产生诊断条目")
    func keysDoNotWriteLogs() throws {
        try withLog { context, log in
            for _ in 0..<100 { context.setKey("tts_playing", "true") }
            #expect(log.snapshot().isEmpty)
            #expect(context.snapshot() == ["tts_playing": "true"])
        }
    }

    @Test("上下文、错误和 breadcrumb 在进入本地日志前脱敏")
    func secretsAreRedactedBeforePersistence() throws {
        try withLog { context, log in
            context.setKey("password", "fixture-password")
            context.setKey("url", "https://reader:fixture-userinfo@example.invalid/page?q=fixture-query#fixture-fragment")
            context.breadcrumb("Authorization: Bearer fixture-bearer")
            context.recordNonFatal(domain: "RSS", message: "password=fixture-error", extra: [
                "cookie": "first=fixture-cookie; second=fixture-second",
                "url": "https://example.invalid/?secret=fixture-extra"
            ])
            let entries = log.snapshot()
            let text = entries.map { $0.message + "\n" + ($0.detail ?? "") }.joined(separator: "\n")
            for secret in ["fixture-password", "fixture-userinfo", "fixture-query", "fixture-fragment", "fixture-bearer", "fixture-error", "fixture-cookie", "fixture-second", "fixture-extra"] {
                #expect(!text.contains(secret))
                #expect(!context.snapshot().values.contains { $0.contains(secret) })
            }
            #expect(text.contains("example.invalid"))
            #expect(text.contains("redacted"))
        }
    }

    @Test("卡顿活动栈进入本地报告，最内层活动在前")
    func activityStackIsRecorded() throws {
        try withLog { context, log in
            context.recordActivityIssue(name: "MainThreadStall", reason: "blocked", activities: ["reader", "paginate"])
            let entry = try #require(log.snapshot().first)
            #expect(entry.severity == .error)
            #expect(entry.category == .crash)
            #expect(entry.detail?.contains("paginate\nreader") == true)
        }
    }

    @Test("上下文有界，新键超限不会淘汰已有键的更新")
    func contextIsBounded() throws {
        try withLog { context, log in
            for index in 0..<(LocalDiagnosticContext.keyLimit + 10) {
                context.setKey("key_\(index)", String(repeating: "x", count: 10_000))
            }
            context.setKey("key_0", "updated")
            let values = context.snapshot()
            #expect(values.count == LocalDiagnosticContext.keyLimit)
            #expect(values["key_0"] == "updated")
            #expect(values.values.allSatisfy { $0.count <= LocalDiagnosticContext.valueLimit })
            #expect(log.snapshot().isEmpty)
            context.recordNonFatal(domain: "test", message: "bounded context")
            #expect(log.snapshot().first?.detail?.contains("[context keys truncated]") == true)
        }
    }

    @Test("多个执行队列更新上下文不会丢失不同键")
    func concurrentUpdates() throws {
        try withLog { context, _ in
            DispatchQueue.concurrentPerform(iterations: 32) { index in
                context.setKey("worker_\(index)", String(index))
            }
            let values = context.snapshot()
            #expect(values.count == 32)
            for index in 0..<32 { #expect(values["worker_\(index)"] == String(index)) }
        }
    }

    @Test("本地导出保留诊断，不要求安装标识或云端回执")
    func reportExportsLocally() throws {
        try withLog { context, log in
            context.recordNonFatal(domain: "RSS", message: "test failure")
            var bundle = DiagnosticReportBundle(
                filename: "test.txt", entries: log.snapshot(),
                session: log.currentSession, uncleanSessions: []
            )
            bundle.acknowledgesReport = false
            let rendered = bundle.render()
            #expect(rendered.contains("test failure"))
            #expect(rendered.contains("RSS:0"))
        }
    }

    @Test("本地报告前言仍位于日志之前")
    func localReportPreface() throws {
        try withLog { _, log in
            var bundle = DiagnosticReportBundle(
                filename: "test.txt", entries: [], session: log.currentSession,
                uncleanSessions: [], acknowledgesReport: false
            )
            bundle.preface = "[問題回報]\n閃退"
            let text = bundle.render()
            let report = try #require(text.range(of: "--- report ---\n[問題回報]\n閃退"))
            let body = try #require(text.range(of: "--- full log"))
            #expect(report.lowerBound < body.lowerBound)
        }
    }
}
