import Foundation

/// 书源及 RSS 共用命令用例；各自沿既有源会话和凭据命名空间，不持有第二份凭据。
struct SourceLoginUiV2Service: Sendable {
    enum Target: Sendable {
        case book(BookSource)
        case rss(RSSSource, RSSStore)
    }

    struct Snapshot: Sendable {
        let state: LoginUiV2.State
        let rows: [LoginUiV2.Row]
        let stored: [String: String]
        var revision: UInt64
        fileprivate let session: BookSourceSession
    }

    struct Outcome: Sendable {
        let snapshot: Snapshot
        let errors: [String: String]
        let close: Bool
        let renderFailure: LoginUiV2.Failure?
        let rerendered: Bool
        let credentialsChanged: Bool
    }

    let target: Target

    func load() async throws -> Snapshot {
        try await run { bridge, access in
            let revision = try access.check()
            return try Self.render(state: .initial, revision: revision, bridge: bridge, access: access)
        }
    }

    func perform(_ action: String, in initial: Snapshot, form: [String: String]) async throws -> Outcome {
        let keys = Set(initial.rows.compactMap(\.key))
        guard initial.rows.contains(where: { $0.action == action }), Set(form.keys) == keys else { throw LoginUiV2.Failure.action }
        let result: Outcome = try await run(session: initial.session) { bridge, access in
            let revision = try access.check(expected: initial.revision)
            let raw = try bridge.evaluateLoginUiV2(state: initial.state, action: action, form: form)
            let command = try LoginUiV2.command(raw)
            _ = try access.check(expected: revision)

            // 与 Android 一样先接收显式 login 命令，再按 state 重绘。失败的重绘保留上次界面。
            let savedRevision = if let login = command.login { try access.save(login, revision: revision) } else { revision }
            var snapshot = initial
            snapshot.revision = savedRevision
            var failure: LoginUiV2.Failure?
            if let state = command.state, !command.close {
                do { snapshot = try Self.render(state: state, revision: savedRevision, bridge: bridge, access: access) }
                catch let error as LoginUiV2.Failure where error != .invalidated { failure = error }
            }
            _ = try access.check(expected: savedRevision)
            return Outcome(snapshot: snapshot, errors: command.errors, close: command.close,
                           renderFailure: failure, rerendered: command.state != nil && !command.close && failure == nil,
                           credentialsChanged: revision != savedRevision)
        }
        if result.credentialsChanged, case .rss(let source, let owner) = target {
            try await MainActor.run {
                try Task.checkCancellation()
                guard owner.source(id: source.id) == source else { throw LoginUiV2.Failure.invalidated }
                owner.authenticationChanged(for: source.id)
            }
        }
        return result
    }

    private static func render(state: LoginUiV2.State, revision: UInt64, bridge: ModernParserBridge, access: Access) throws -> Snapshot {
        let raw = try bridge.evaluateLoginUiV2(state: state)
        let rows = try SourcePerfTrace.span("source.login.v2.rows", "bytes=\(raw?.utf8.count ?? 0) main=\(Thread.isMainThread)") {
            try LoginUiV2.rows(raw)
        }
        _ = try access.check(expected: revision)
        let credentials = LoginManager.shared.getLoginInfo(sourceUrl: access.key) ?? [:]
        var stored: [String: String] = [:]
        for key in rows.compactMap(\.key) { stored[key] = credentials[key] }
        _ = try access.check(expected: revision)
        return Snapshot(state: state, rows: rows, stored: stored, revision: revision, session: access.session)
    }

    private struct Access: Sendable {
        let key: String
        let session: BookSourceSession

        func check(expected: UInt64? = nil) throws -> UInt64 {
            try Task.checkCancellation()
            guard session.isActive else { throw LoginUiV2.Failure.invalidated }
            let revision = LoginManager.shared.loginInfoRevision(sourceUrl: key)
            guard expected == nil || expected == revision else { throw LoginUiV2.Failure.invalidated }
            return revision
        }

        func save(_ values: [String: String], revision: UInt64) throws -> UInt64 {
            _ = try check(expected: revision)
            if LoginManager.shared.getLoginInfo(sourceUrl: key) == values { return revision }
            let saved: UInt64?
            if let runtime = session.runtimeOverrides?.state {
                var accepted: UInt64?
                runtime.mutateCredentials { expected in
                    guard expected == revision, !Task.isCancelled else { return nil }
                    accepted = LoginManager.shared.storeLoginInfo(sourceUrl: key, info: values, expectedRevision: revision)
                    return accepted
                }
                saved = accepted
            } else {
                saved = LoginManager.shared.storeLoginInfo(sourceUrl: key, info: values, expectedRevision: revision)
            }
            guard let saved else {
                _ = try check(expected: revision)
                throw LoginUiV2.Failure.credentials
            }
            return saved
        }
    }

    private func run<T: Sendable>(session retainedSession: BookSourceSession? = nil,
                                  _ operation: @escaping @Sendable (ModernParserBridge, Access) throws -> T) async throws -> T {
        try Task.checkCancellation()
        return try await SourceDiagnosticContext.$restrictedTask.withValue(true) {
            switch target {
            case .book(let source):
                let session = retainedSession ?? BookSourceSession.session(for: source)
                let access = Access(key: source.bookSourceUrl, session: session)
                do { return try await session.parse { bridge in try operation(bridge, access) } }
                catch BookSourceSession.SessionFailure.invalidated { throw LoginUiV2.Failure.invalidated }
            case .rss(let source, let owner):
                let runtime = try await RSSRuntime.make(source: source, owner: owner)
                return try await runtime.run { host in
                    try await host.run { bridge in
                        try operation(bridge, Access(key: RSSRuntime.authenticationKey(for: source), session: runtime.session))
                    }
                }
            }
        }
    }
}
