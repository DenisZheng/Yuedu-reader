import Foundation

struct RSSRuntimeSnapshot: Equatable, Sendable {
    var variableJSON: String?
    var values: [String: String] = [:]
    var variableIsStored = false
}

/// 共享bridge的同步变量接口。只持有当前源会话的工作副本；落盘唯一由RSSStore完成。
final class RSSRuntimeState: SourceRuntimeStateAccess, @unchecked Sendable {
    private let lock = NSLock()
    private var value: RSSRuntimeSnapshot
    private var active = true
    private let authenticationKey: String?
    private var credentialRevision: UInt64?
    private var credentialWriteFailed = false
    private var timedOut = false
    var didTimeOut: Bool { lock.withLock { timedOut } }
    func noteTimeout() { lock.withLock { timedOut = true }; invalidate() }
    private var cancellations: [UUID: @Sendable () -> Void] = [:]

    func addCancellation(_ action: @escaping @Sendable () -> Void) -> UUID? {
        let token = lock.withLock { () -> UUID? in
            guard active else { return nil }
            let id = UUID()
            cancellations[id] = action
            return id
        }
        if token == nil { action() }
        return token
    }
    func removeCancellation(_ id: UUID) { _ = lock.withLock { cancellations.removeValue(forKey: id) } }
    var isActive: Bool { lock.withLock { active } }
    var didFailCredentialWrite: Bool { lock.withLock { credentialWriteFailed } }
    var isCurrent: Bool {
        let current = lock.withLock { (active, credentialRevision) }
        guard current.0 else { return false }
        guard let authenticationKey, let revision = current.1 else { return true }
        return LoginManager.shared.loginInfoRevision(sourceUrl: authenticationKey) == revision
    }
    func invalidate() {
        let pending = lock.withLock { () -> (UInt64?, [@Sendable () -> Void]) in
            guard active else { return (nil, []) }
            active = false
            let actions = Array(cancellations.values)
            cancellations.removeAll()
            return (credentialRevision, actions)
        }
        for action in pending.1 { action() }
        if let authenticationKey, let revision = pending.0 {
            LoginManager.shared.invalidateRuntimeAccess(sourceUrl: authenticationKey, expectedRevision: revision)
        }
    }
    func mutateCredentials(_ mutation: (UInt64?) -> UInt64?) {
        // CAS与active检查是同一个临界区；不能在检查后被撤销，再把旧凭据写回。
        let mustInvalidate = lock.withLock { () -> Bool in
            guard active else { return false }
            guard isActiveRevision(credentialRevision) else { return true }
            guard let updated = mutation(credentialRevision) else {
                credentialWriteFailed = isActiveRevision(credentialRevision)
                return true
            }
            credentialRevision = updated
            return false
        }
        if mustInvalidate { invalidate() }
    }
    func withCurrentAccess<T: Sendable>(_ body: @Sendable () throws -> T) throws -> T {
        return try lock.withLock {
            guard active else { throw CancellationError() }
            if let authenticationKey, let credentialRevision {
                return try LoginManager.shared.withLoginInfoRevision(sourceUrl: authenticationKey, expectedRevision: credentialRevision, body)
            } else { return try body() }
        }
    }
    private func isActiveRevision(_ expected: UInt64?) -> Bool {
        guard let authenticationKey else { return true }
        return LoginManager.shared.loginInfoRevision(sourceUrl: authenticationKey) == expected
    }

    init(_ value: RSSRuntimeSnapshot, authenticationKey: String? = nil) {
        self.value = value
        self.authenticationKey = authenticationKey
        self.credentialRevision = authenticationKey.map { LoginManager.shared.loginInfoRevision(sourceUrl: $0) }
    }
    var snapshot: RSSRuntimeSnapshot { lock.withLock { value } }

    func sourceVariableJSON(for sourceUrl: String) -> String? { lock.withLock { value.variableJSON } }
    func setSourceVariableJSON(_ json: String?, for sourceUrl: String) {
        // 空串表示显式清除，不能在下次启动重新套用导入配置中的初值。
        lock.withLock { if active { value.variableJSON = json ?? ""; value.variableIsStored = true } }
    }
    func sourceValue(for sourceUrl: String, key: String) -> String? { lock.withLock { value.values[key] } }
    func setSourceValue(_ value: String, for sourceUrl: String, key: String) {
        lock.withLock { if active { self.value.values[key] = value } }
    }
    func sourceVariables(for sourceUrl: String) -> [String: Any] {
        guard let raw = sourceVariableJSON(for: sourceUrl), let data = raw.data(using: .utf8) else { return [:] }
        do { return try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:] }
        catch { return [:] } // opaque token/数组也是合法source.getVariable值，不等同键值对象。
    }
}
