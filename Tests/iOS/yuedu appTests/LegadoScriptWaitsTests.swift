import Foundation
import os
import Testing
@testable import yuedu_app

struct LegadoScriptWaitsTests {
    @Test func concurrentWaitsKeepTheClockMonotonic() async {
        let waits = LegadoScriptWaits()
        let lastReads = OSAllocatedUnfairLock(initialState: [TimeInterval]())
        let deadline = DispatchTime.now() + .milliseconds(1500)
        let group = DispatchGroup()
        let queue = DispatchQueue.global(qos: .userInitiated)

        // 模拟并发 java 请求切换等待状态，以及 JS 引擎同时读等待时间。
        for _ in 0..<6 {
            queue.async(group: group) {
                repeat { waits.during {} } while DispatchTime.now() < deadline
            }
        }
        for _ in 0..<3 {
            queue.async(group: group) {
                var previous: TimeInterval = 0
                repeat {
                    let next = waits.waitedSeconds
                    #expect(next >= previous)
                    previous = next
                } while DispatchTime.now() < deadline
                let value = previous
                lastReads.withLock { $0.append(value) }
            }
        }

        await withCheckedContinuation { continuation in
            group.notify(queue: queue) { continuation.resume() }
        }
        let reads = lastReads.withLock { $0 }
        let total = waits.waitedSeconds
        #expect(!waits.isWaiting)
        #expect(reads.count == 3)
        #expect(total > 0)
        #expect(reads.allSatisfy { $0 <= total })
    }
}
