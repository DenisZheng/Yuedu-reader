import Foundation
import Testing
import UserNotifications
@testable import yuedu_app

@Suite("RSS 本地通知授权", .serialized)
struct RSSNotificationAuthorizationTests {
    private actor Center {
        let status: UNAuthorizationStatus
        let granted: Bool
        let fails: Bool
        private(set) var requestCount = 0

        init(_ status: UNAuthorizationStatus, granted: Bool = true, fails: Bool = false) {
            self.status = status
            self.granted = granted
            self.fails = fails
        }

        func settings() -> UNAuthorizationStatus { status }
        func request() throws -> Bool {
            requestCount += 1
            if fails { throw TestError.unavailable }
            return granted
        }
    }
    private enum TestError: Error { case unavailable }

    private func authorization(_ center: Center) -> RSSNotificationAuthorization {
        RSSNotificationAuthorization(status: { await center.settings() }, request: { try await center.request() })
    }

    @Test("读取系统状态不请求权限")
    func readingDoesNotRequest() async {
        let center = Center(.notDetermined)
        #expect(await authorization(center).currentStatus() == .notDetermined)
        #expect(await center.requestCount == 0)
    }

    @Test("首次由用户请求时只调用一次系统授权")
    func firstRequest() async throws {
        let center = Center(.notDetermined)
        #expect(try await authorization(center).requestIfNeeded())
        #expect(await center.requestCount == 1)
    }

    @Test("用户拒绝不会被视为成功")
    func refusal() async throws {
        let center = Center(.notDetermined, granted: false)
        #expect(try await !authorization(center).requestIfNeeded())
        #expect(await center.requestCount == 1)
    }

    @Test("已拒绝不重复请求")
    func deniedDoesNotReprompt() async throws {
        let center = Center(.denied)
        #expect(try await !authorization(center).requestIfNeeded())
        #expect(await center.requestCount == 0)
    }

    private static var authorizedStatuses: [UNAuthorizationStatus] {
        var values: [UNAuthorizationStatus] = [.authorized, .provisional]
        #if os(iOS)
        values.append(.ephemeral)
        #endif
        return values
    }

    @Test("已有权限不重复请求", arguments: authorizedStatuses)
    func authorizedDoesNotReprompt(_ status: UNAuthorizationStatus) async throws {
        let center = Center(status)
        #expect(try await authorization(center).requestIfNeeded())
        #expect(await center.requestCount == 0)
    }

    @Test("系统失败向调用方传播")
    func failureIsPropagated() async {
        let center = Center(.notDetermined, fails: true)
        await #expect(throws: TestError.self) { try await authorization(center).requestIfNeeded() }
        #expect(await center.requestCount == 1)
    }

    @Test("系统请求返回后已取消，不发布旧的授权成功")
    func cancellationAfterRequest() async {
        let center = Center(.notDetermined)
        let task = Task {
            let service = RSSNotificationAuthorization(status: { .notDetermined }, request: {
                let granted = try await center.request()
                withUnsafeCurrentTask { $0?.cancel() }
                return granted
            })
            return try await service.requestIfNeeded()
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(await center.requestCount == 1)
    }

    @Test("状态读取期间取消，不再弹出系统授权")
    func cancellationBeforePrompt() async {
        let center = Center(.notDetermined)
        let task = Task {
            let service = RSSNotificationAuthorization(status: {
                withUnsafeCurrentTask { $0?.cancel() }
                return .notDetermined
            }, request: { try await center.request() })
            _ = try await service.requestIfNeeded()
        }
        do {
            _ = try await task.value
            Issue.record("取消应传播 CancellationError")
        } catch is CancellationError {
            #expect(await center.requestCount == 0)
        } catch {
            Issue.record(error)
        }
    }
}
