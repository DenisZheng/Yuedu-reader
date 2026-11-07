import Foundation
import Observation

/// Counts and records the changes to what `read` reads on `@Observable` objects — the test
/// side of `objectWillChange.sink` / `$property.dropFirst().sink`, which `GlobalSettings`
/// no longer has.
///
/// `withObservationTracking` reports the first change, before it lands: the count and the
/// mutating thread are taken there; the new value is read, and the tracking re-armed, on
/// the next main-queue turn. Drain the main queue (`RunLoop.main.run(until: Date())`)
/// before reading `values`.
final class ObservationRecorder<Value>: @unchecked Sendable {
    private(set) var changeCount = 0
    private(set) var values: [Value] = []
    private(set) var changedOffMain = false
    /// 在新值真正采样后通知测试；比运行一个已到期的 RunLoop 更明确。
    var onRecord: ((Value) -> Void)?
    private let read: () -> Value
    private var isActive = true

    init(_ read: @escaping () -> Value) {
        self.read = read
        arm()
    }

    func cancel() { isActive = false }

    private func arm() {
        withObservationTracking {
            _ = read()
        } onChange: { [weak self] in
            guard let self, self.isActive else { return }
            self.changeCount += 1
            if !Thread.isMainThread { self.changedOffMain = true }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.isActive else { return }
                let value = self.read()
                self.values.append(value)
                self.arm()
                self.onRecord?(value)
            }
        }
    }
}
