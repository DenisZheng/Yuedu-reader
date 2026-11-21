import Foundation
import os
import Testing
@testable import yuedu_app

/// 只运行自建脚本，验证移除原文控制台输出不会改变接口、提示或错误传播。
@Suite("源脚本诊断接口兼容", .serialized, .timeLimit(.minutes(1)))
struct SourceDebugLoggingCompatibilityTests {
    @Test("脚本print和logType仍可调用，后续规则正常执行")
    func informationalInterfacesStillWork() async throws {
        let value = try await SourceScriptThread.run {
            let engine = JSCoreEngine()
            return engine.evaluate("print('local fixture'); java.logType('local fixture'); 40 + 2;")
        }
        #expect(value == "42")
    }

    @Test("异常仍经原错误回调传播，而不是被静默当作成功")
    func exceptionStillReachesErrorHandler() async throws {
        let count = OSAllocatedUnfairLock(initialState: 0)
        let failed = try await SourceScriptThread.run {
            let engine = JSCoreEngine()
            // 使用RSS现有受限诊断路径，测试不向控制台打印脚本异常原文。
            engine.sourcePropertiesJSON = Data("{}".utf8)
            engine.errorHandler = { _, _ in count.withLock { $0 += 1 } }
            return engine.evaluate("throw new Error('local fixture error');") == nil && engine.lastError != nil
        }
        #expect(failed)
        #expect(count.withLock { $0 } == 1)
    }

    @Test("toast仍把原提示交付给主线程回调")
    @MainActor
    func toastStillReachesUserInterface() async throws {
        let messages = AsyncStream<String>.makeStream()
        defer { messages.continuation.finish() }
        let value = try await SourceScriptThread.run {
            let engine = JSCoreEngine()
            engine.toastHandler = { message in
                #expect(Thread.isMainThread)
                messages.continuation.yield(message)
            }
            return engine.evaluate("java.toast('local fixture toast'); 'done';")
        }
        try #require(value == "done")
        var iterator = messages.stream.makeAsyncIterator()
        #expect(await iterator.next() == "local fixture toast")
    }
}
