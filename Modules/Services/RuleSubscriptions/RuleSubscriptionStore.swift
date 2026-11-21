import Foundation
import Observation

@MainActor @Observable
final class RuleSubscriptionStore {
    static let shared = RuleSubscriptionStore(file: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("rule_subscriptions_v1.json"))
    enum Outcome: Equatable {
        case checking, pending(Int), upToDate, updated(Int), cancelled, failed(String)
        var message: String {
            switch self {
            case .checking: localized("正在檢查更新…")
            case .pending(let count): String(format: localized("有 %d 項配置待確認更新"), count)
            case .upToDate: localized("配置已是最新")
            case .updated(let count): String(format: localized("已更新 %d 項配置"), count)
            case .cancelled: localized("更新已取消")
            case .failed(let message): message
            }
        }
    }
    private(set) var subscriptions: [RuleSubscription] = []
    private(set) var outcomes: [UUID: Outcome] = [:]
    private(set) var pending: [UUID: RuleSubscriptionUpdatePlan] = [:]
    private(set) var isLoaded = false
    private(set) var failureMessage: String?
    private(set) var writeCount = 0
    @ObservationIgnored private let disk: RuleSubscriptionDisk
    @ObservationIgnored private let gate = SourceTurnGate()
    @ObservationIgnored private let fetch: RuleSubscriptionUpdateService.Fetch
    @ObservationIgnored private let prepare: RuleSubscriptionUpdateService.Prepare
    @ObservationIgnored private var generations: [UUID: UInt64] = [:]
    @ObservationIgnored private var checks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var foregroundTask: Task<Void, Never>?
    @ObservationIgnored private var active = false

    init(file: URL, fetch: @escaping RuleSubscriptionUpdateService.Fetch = RuleSubscriptionUpdateService.fetch,
         prepare: @escaping RuleSubscriptionUpdateService.Prepare = RuleSubscriptionUpdateService.prepare) {
        disk = RuleSubscriptionDisk(file: file); self.fetch = fetch; self.prepare = prepare
    }

    func load() async throws {
        try await gate.acquireUnlessCancelled(priority: Task.currentPriority)
        defer { gate.release() }
        try await loadIfNeeded()
    }
    private func loadIfNeeded() async throws {
        guard !isLoaded else { return }
        do { subscriptions = try await disk.load(); isLoaded = true; failureMessage = nil }
        catch { failureMessage = Self.safeMessage(error); throw error }
    }
    private func mutate(_ transform: ([RuleSubscription]) throws -> [RuleSubscription]) async throws {
        try await gate.acquireUnlessCancelled(priority: Task.currentPriority)
        defer { gate.release() }
        try await loadIfNeeded()
        let next = try transform(subscriptions)
        guard next.count <= 128 else { throw RuleSubscriptionFailure.tooLarge }
        guard next != subscriptions else { return }
        try Task.checkCancellation()
        try await disk.save(next)
        subscriptions = next; writeCount += 1; failureMessage = nil
    }

    func upsert(_ input: RuleSubscription) async throws {
        var value = try input.validated()
        cancel(value.id)
        try await mutate { current in
            var next = current
            if let index = next.firstIndex(where: { $0.id == value.id }) {
                if next[index].url != value.url || next[index].type != value.type {
                    value.update = 0; value.lastSuccessfulCheck = nil
                    value.authorVersions = nil; value.replacementIDs = nil
                }
                next[index] = value
            } else { value.customOrder = next.count; next.append(value) }
            return next
        }
        outcomes[value.id] = nil
    }
    func delete(_ id: UUID) async throws {
        cancel(id)
        try await mutate { $0.filter { $0.id != id } }
        outcomes[id] = nil
    }
    func cancel(_ id: UUID) {
        generations[id, default: 0] &+= 1
        checks[id]?.cancel(); checks[id] = nil; pending[id] = nil
        if outcomes[id] != nil { outcomes[id] = .cancelled }
    }

    func check(_ id: UUID, force: Bool = true, now: Date = Date()) async {
        do { try await load() }
        catch { outcomes[id] = .failed(Self.safeMessage(error)); return }
        guard let value = subscriptions.first(where: { $0.id == id }), force || value.isDue(at: now) else { return }
        cancel(id)
        let ticket = generations[id, default: 0]
        outcomes[id] = .checking
        let task = Task { await performCheck(value, ticket: ticket, now: now) }
        checks[id] = task
        await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
        if current(id, ticket) { checks[id] = nil }
    }
    private func performCheck(_ value: RuleSubscription, ticket: UInt64, now: Date) async {
        do {
            try await mutate { current in
                try authorize(value.id, ticket)
                return current.map { item in
                    guard item.id == value.id else { return item }
                    var item = item; item.update = Int64(now.timeIntervalSince1970 * 1_000); return item
                }
            }
            try authorize(value.id, ticket)
            guard let address = URL(string: value.url) else { throw RuleSubscriptionFailure.invalidConfiguration }
            let bytes = try await fetch(address, RuleSubscriptionUpdateService.maximumBytes)
            guard bytes.count <= RuleSubscriptionUpdateService.maximumBytes else { throw RuleSubscriptionFailure.tooLarge }
            try authorize(value.id, ticket)
            let plan = try await prepare(value, bytes)
            try authorize(value.id, ticket)
            if plan.count > 0, !value.silentUpdate {
                pending[value.id] = plan; outcomes[value.id] = .pending(plan.count)
            } else {
                try await apply(plan, id: value.id, ticket: ticket, now: now)
            }
        } catch is CancellationError {
            if current(value.id, ticket) { outcomes[value.id] = .cancelled }
        } catch {
            if current(value.id, ticket) { outcomes[value.id] = .failed(Self.safeMessage(error)) }
        }
    }
    func confirm(_ id: UUID, now: Date = Date()) async {
        guard let outcome = outcomes[id], case .pending = outcome, let plan = pending[id] else { return }
        let ticket = generations[id, default: 0]
        outcomes[id] = .checking
        let task = Task {
            do { try await apply(plan, id: id, ticket: ticket, now: now) }
            catch is CancellationError { if current(id, ticket) { outcomes[id] = .cancelled } }
            catch { if current(id, ticket) { outcomes[id] = .failed(Self.safeMessage(error)) } }
        }
        checks[id] = task
        await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
        if current(id, ticket) { checks[id] = nil }
    }
    private func apply(_ plan: RuleSubscriptionUpdatePlan, id: UUID, ticket: UInt64, now: Date) async throws {
        try authorize(id, ticket)
        try await plan.apply { [weak self] in
            guard let self else { throw CancellationError() }
            try self.authorize(id, ticket)
        }
        try await mutate { current in
            try authorize(id, ticket)
            return current.map { item in
                guard item.id == id else { return item }
                var item = item
                item.lastSuccessfulCheck = Int64(now.timeIntervalSince1970 * 1_000)
                if item.type == .replaceRules { item.replacementIDs = plan.replacementIDs }
                else { item.authorVersions = plan.authorVersions }
                return item
            }
        }
        pending[id] = nil
        outcomes[id] = plan.count == 0 ? .upToDate : .updated(plan.count)
    }
    private func current(_ id: UUID, _ ticket: UInt64) -> Bool {
        generations[id] == ticket && subscriptions.contains { $0.id == id }
    }
    private func authorize(_ id: UUID, _ ticket: UInt64) throws {
        try Task.checkCancellation()
        guard current(id, ticket) else { throw RuleSubscriptionFailure.stale }
    }

    /// 每次前台激活只做一次到期扫描，串行下载；不调度常驻后台或自动运行源脚本。
    func setActive(_ active: Bool) {
        guard self.active != active else { return }
        self.active = active
        foregroundTask?.cancel()
        if !active {
            for id in Array(checks.keys) { cancel(id) }
            return
        }
        foregroundTask = Task {
            do {
                try await load()
                let ids = subscriptions.filter { $0.autoUpdate && $0.isDue(at: Date()) }.map(\.id)
                for id in ids {
                    guard self.active, !Task.isCancelled else { return }
                    if pending[id] == nil, checks[id] == nil { await check(id, force: false) }
                }
            } catch { failureMessage = Self.safeMessage(error) }
        }
    }
    func waitForForegroundWork() async { await foregroundTask?.value }
    private static func safeMessage(_ error: Error) -> String {
        (error as? RuleSubscriptionFailure)?.localizedDescription ?? localized("規則訂閱操作失敗，請重試")
    }
}
