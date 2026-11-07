import Foundation

/// RSS只适配上下文和模型；JS生命周期、AnalyzeUrl、登录检查、网络和规则回调均复用共享会话。
struct RSSRuntime: Sendable {
    let source: RSSSource
    let session: BookSourceSession
    let state: RSSRuntimeState
    let owner: RSSStore?
    let ticket: RSSRequestTicket?
    let requestSession: URLSession

    static func authenticationKey(for source: RSSSource) -> String { "rss." + RSSIdentity.digest([source.id, source.sourceKey]) }

    static func make(source: RSSSource, owner: RSSStore? = nil,
                     requestSession: URLSession = LegadoJSBridge.requestSession) async throws -> RSSRuntime {
        let initial: RSSRuntimeSnapshot
        let ownerID: String
        let ticket: RSSRequestTicket?
        if let owner {
            let context = try await MainActor.run { (try owner.runtimeSnapshot(for: source), owner.runtimeIdentity,
                                                owner.requestTicket(for: source.id), owner.source(id: source.id)) }
            guard context.3 == source, let currentTicket = context.2 else { throw CancellationError() }
            initial = context.0; ownerID = context.1; ticket = currentTicket
        } else {
            initial = RSSRuntimeSnapshot(variableJSON: source.variable)
            ownerID = "transient"; ticket = nil
        }
        try Task.checkCancellation()
        let authenticationKey = authenticationKey(for: source)
        let properties: Data = try SourcePerfTrace.span("rss.runtime.prepare", "main=\(Thread.isMainThread) jsBytes=\(source.jsLib?.utf8.count ?? 0)") {
            try JSONSerialization.data(withJSONObject: LegadoSourceJSONParser.exportJSON(from: source),
                                       options: [.sortedKeys, .withoutEscapingSlashes])
        }
        let identity = RSSIdentity.digest([ownerID, source.id, String(decoding: properties, as: UTF8.self),
                                           String(ticket?.authenticationRevision ?? 0)])
        let overrides = SourceRuntimeOverrides(identity: identity, authenticationKey: authenticationKey,
                                               propertiesJSON: properties, state: RSSRuntimeState(initial, authenticationKey: authenticationKey),
                                               headerScope: SourceRequestHeaderScope(urls: [source.sourceKey, source.loginUrl ?? ""].compactMap {
                                                   URL(string: LegadoRSSScraper.normalizedRequestURL(RSSSource.strippingLegadoURLOptions($0)))
                                               }))
        let session = BookSourceSession.session(for: scriptSource(source), runtimeOverrides: overrides, requestSession: requestSession)
        guard let state = session.runtimeOverrides?.state as? RSSRuntimeState else { throw ScraperError.invalidRule("runtime") }
        if let owner, let ticket, !(await owner.registerRuntime(state, source: source, ticket: ticket)) {
            state.invalidate()
            throw CancellationError()
        }
        return RSSRuntime(source: source, session: session, state: state, owner: owner, ticket: ticket, requestSession: requestSession)
    }

    private final class OperationState: @unchecked Sendable {
        private let lock = NSLock()
        private var running = false
        func begin() { lock.withLock { running = true } }
        func finish() { lock.withLock { running = false } }
        func cancel(_ action: () -> Void) { lock.withLock { if running { action() } } }
    }

    func run<T: Sendable>(_ work: @Sendable (SourceScriptHost<ModernParserBridge>) async throws -> T) async throws -> T {
        try await execute(allowRetry: true, work)
    }

    private func execute<T: Sendable>(allowRetry: Bool,
                                     _ work: @Sendable (SourceScriptHost<ModernParserBridge>) async throws -> T) async throws -> T {
        let operation = OperationState()
        do {
            return try await withTaskCancellationHandler { () async throws -> T in
                try await SourceDiagnosticContext.$restrictedTask.withValue(true) { () async throws -> T in
                    try await session.operation { host -> T in
                        guard state.isCurrent else { session.invalidate(); throw BookSourceSession.SessionFailure.invalidated }
                        operation.begin()
                        defer { operation.finish() }
                        try Task.checkCancellation()
                        let result: Result<T, Error>
                        do { result = .success(try await work(host)) }
                        catch { result = .failure(error) }
                        try Task.checkCancellation()
                        if state.didTimeOut { throw ScraperError.executionTimedOut }
                        if case .failure(let error) = result, let error = error as? ModernParserBridgeError,
                           case .timeout = error {
                            session.invalidate()
                            throw ScraperError.executionTimedOut
                        }
                        if state.didFailCredentialWrite { throw ScraperError.scriptFailure }
                        guard state.isCurrent else { session.invalidate(); throw CancellationError() }
                        if let owner, let ticket {
                            guard await owner.accepts(ticket) else { session.invalidate(); throw CancellationError() }
                            guard await owner.mergeRuntimeSnapshot(state.snapshot, ticket: ticket, runtime: state) else {
                                session.invalidate()
                                throw CancellationError()
                            }
                        }
                        do { return try result.get() }
                        catch SourceRuntimeRequirement.interactionRequired { session.invalidate(); throw ScraperError.interactionRequired }
                        catch ModernParserBridgeError.parseError { throw ScraperError.scriptFailure }
                        catch ModernParserBridgeError.invalidURL { throw ScraperError.invalidURL }
                        catch let error as URLError where error.code == .cancelled { throw CancellationError() }
                    }
                }
            } onCancel: {
                operation.cancel { session.invalidate() }
            }
        } catch BookSourceSession.SessionFailure.invalidated {
            // 另一个已取消的调用丢弃了共享JS上下文；未执行的排队调用只重绑一次，不能重放已执行脚本。
            guard allowRetry, !Task.isCancelled else { throw CancellationError() }
            if let owner, let ticket, !(await owner.accepts(ticket)) { throw CancellationError() }
            let fresh = try await Self.make(source: source, owner: owner, requestSession: requestSession)
            return try await fresh.execute(allowRetry: false, work)
        }
    }

    static func scriptSource(_ source: RSSSource) -> BookSource {
        var book = BookSource(bookSourceUrl: source.sourceKey, bookSourceName: "RSS " + RSSIdentity.digest([source.id]).prefix(12))
        // 此字段属于书源域，不填RSS的type；脚本source.type由原始RSS元数据提供。
        book.bookSourceType = 0
        book.header = source.header ?? ""
        book.jsLib = source.jsLib ?? ""
        book.loginUrl = source.loginUrl ?? ""
        book.loginUi = source.loginUi ?? ""
        book.loginCheckJs = source.loginCheckJs ?? ""
        book.concurrentRate = source.concurrentRate ?? ""
        book.enabledCookieJar = source.enabledCookieJar
        book.enabled = source.enabled
        book.variableComment = source.variableComment ?? ""
        book.coverDecodeJs = source.coverDecodeJs ?? ""
        book.searchUrl = source.searchUrl ?? ""
        return book
    }
}
