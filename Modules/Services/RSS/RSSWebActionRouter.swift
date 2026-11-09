import Foundation
import Observation

/// 网页/源脚本只提交值意图；验证后一次性发布原生导航，不让网页数据升级为其他来源的脚本/认证权限。
@MainActor @Observable
final class RSSWebActionRouter {
    enum Target {
        case feed(RSSSource, [RSSSortEntry]?)
        case web(RSSSource, RSSOpenTarget, String?)
        case search(String, String?)
        case login(RSSSource)
        case photo(RSSSource, String, URL?, Bool, RSSOpenTarget.RequestContext?)
        case book(OnlineBook)
        case explore(BookSource, String, String)
        case video(RSSStore?, String?, String, VideoStream, RSSMediaResourceSession, String)
    }
    struct Destination: Identifiable, Hashable {
        let id = UUID()
        var target: Target
        static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
        func hash(into hasher: inout Hasher) { hasher.combine(id) }
    }
    struct BookRequest: Sendable { var source: BookSource; var url: String }
    struct Confirmation: Identifiable {
        enum Kind { case external(URL), source(RSSSource), book(BookRequest), explore(BookSource, String, String) }
        let id = UUID()
        var request: RSSWebActionRequest
        var kind: Kind
        var display: String
    }
    private enum Prepared { case destination(Target), confirmation(Confirmation) }
    var destination: Destination?
    var confirmation: Confirmation?
    var error: String?
    private(set) var isLoading = false
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var generation = 0

    func receive(_ request: RSSWebActionRequest, source: RSSSource, owner: RSSStore) throws {
        try validate(request, owner: owner)
        guard source.id == request.sourceID, !isLoading, destination == nil, confirmation == nil else { throw RSSWebFailure.actionUnavailable }
        generation &+= 1
        let id = generation
        error = nil
        isLoading = true
        task = Task { [weak self] in
            guard let self else { return }
            defer { if id == generation { isLoading = false; task = nil } }
            do {
                let result = try await prepare(request, current: source, owner: owner)
                try Task.checkCancellation()
                try validate(request, owner: owner)
                guard id == generation else { return }
                switch result {
                case .destination(let value): destination = .init(target: value)
                case .confirmation(let value): confirmation = value
                }
            } catch is CancellationError { return }
            catch { if id == generation { self.error = (error as? RSSWebFailure)?.localizedDescription ?? RSSWebFailure.actionUnavailable.localizedDescription } }
        }
    }
    func playMedia(_ media: RSSMediaReference, article: RSSArticleRecord, source: RSSSource, owner: RSSStore) {
        guard let current = owner.article(id: article.id), current.sourceId == source.id,
              current.media?.contains(media) == true, media.articleID == current.id,
              media.kind == .video || media.kind == .audio else {
            error = RSSWebFailure.actionUnavailable.localizedDescription
            return
        }
        let action = RSSWebAction.playVideo(url: media.url, title: mediaTitle(media), attachmentKey: media.key)
        let request = RSSWebActionRequest(action: action, authority: .attachment, sourceID: source.id,
            ownerID: owner.runtimeIdentity, ticket: owner.requestTicket(for: source.id),
            baseURL: URL(string: article.link) ?? source.articleLinkBaseURL,
            credentialRevision: LoginManager.shared.loginInfoRevision(sourceUrl: RSSRuntime.authenticationKey(for: source)),
            article: .init(title: article.title, link: article.link, category: article.categoryName ?? "", id: article.id))
        do { try receive(request, source: source, owner: owner) }
        catch { self.error = RSSWebFailure.actionUnavailable.localizedDescription }
    }
    private func mediaTitle(_ media: RSSMediaReference) -> String {
        let name = URL(string: media.url)?.lastPathComponent ?? localized("附件")
        return String(name.prefix(160))
    }

    func cancelPending() {
        generation &+= 1
        task?.cancel(); task = nil
        isLoading = false
        confirmation = nil
    }
    func acceptConfirmation(owner: RSSStore, openExternal: @escaping (URL) -> Void) {
        guard let pending = confirmation else { return }
        confirmation = nil
        do { try validate(pending.request, owner: owner) }
        catch { self.error = RSSWebFailure.actionUnavailable.localizedDescription; return }
        switch pending.kind {
        case .external(let url): openExternal(url)
        case .source(let source):
            guard let current = owner.source(id: source.id) else { error = RSSWebFailure.actionUnavailable.localizedDescription; return }
            var request = pending.request
            request.sourceID = current.id
            request.ticket = owner.requestTicket(for: current.id)
            request.baseURL = current.articleLinkBaseURL
            request.context = nil
            request.credentialRevision = LoginManager.shared.loginInfoRevision(sourceUrl: RSSRuntime.authenticationKey(for: current))
            do { try receive(request, source: current, owner: owner) }
            catch { self.error = RSSWebFailure.actionUnavailable.localizedDescription }
        case .book(let input):
            runConfirmed(pending.request, owner: owner) {
                guard let current = BookSourceStore.shared.source(id: input.source.id) else { throw RSSWebFailure.actionUnavailable }
                let safe = try await Self.bookRequest(input.url, sources: [current], base: nil)
                let package = try await SourceDiagnosticContext.$restrictedTask.withValue(true) {
                    try await BookSourceFetcher().fetchBookInfoPackage(url: safe.url, source: safe.source, writesCache: false)
                }
                return .book(package.onlineBook)
            }
        case .explore(let source, let url, let title):
            guard let current = BookSourceStore.shared.source(id: source.id) else { error = RSSWebFailure.actionUnavailable.localizedDescription; return }
            do {
                let safe = try Self.bookURL(url, source: current)
                destination = .init(target: .explore(current, safe.absoluteString, title))
            } catch { self.error = RSSWebFailure.actionUnavailable.localizedDescription }
        }
    }
    private func runConfirmed(_ request: RSSWebActionRequest, owner: RSSStore, work: @escaping () async throws -> Target) {
        cancelPending()
        let id = generation
        isLoading = true
        task = Task { [weak self] in
            guard let self else { return }
            defer { if id == generation { isLoading = false; task = nil } }
            do {
                let result = try await work()
                try Task.checkCancellation()
                try validate(request, owner: owner)
                guard id == generation else { return }
                destination = .init(target: result)
            } catch is CancellationError { return }
            catch { if id == generation { self.error = RSSWebFailure.actionUnavailable.localizedDescription } }
        }
    }
    private func validate(_ request: RSSWebActionRequest, owner: RSSStore) throws {
        guard request.ownerID == owner.runtimeIdentity, let ticket = request.ticket, ticket.sourceID == request.sourceID,
              owner.accepts(ticket), let source = owner.source(id: request.sourceID),
              request.credentialRevision == LoginManager.shared.loginInfoRevision(sourceUrl: RSSRuntime.authenticationKey(for: source))
        else { throw CancellationError() }
    }
    private func prepare(_ request: RSSWebActionRequest, current source: RSSSource, owner: RSSStore) async throws -> Prepared {
        let targetOrigin: String?
        switch request.action {
        case .rss(_, _, let origin), .sort(_, _, let origin), .login(let origin): targetOrigin = origin
        default: targetOrigin = nil
        }
        if let targetOrigin, !targetOrigin.isEmpty, targetOrigin != source.id, targetOrigin != source.sourceKey {
            let sources = owner.sources
            guard let selected = await SourceScriptThread.run({ sources.first { $0.id == targetOrigin || $0.sourceKey == targetOrigin } }) else { throw RSSWebFailure.actionUnavailable }
            return .confirmation(.init(request: request, kind: .source(selected), display: selected.name))
        }
        let trusted = request.authority == .sourceRule
        let attachment = request.authority == .attachment
        let base = request.baseURL ?? source.articleLinkBaseURL
        switch request.action {
        case .sort(let raw, let title, _):
            let entries: [RSSSortEntry]?
            if let raw, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                entries = try await Self.sortEntries(raw, title: title, base: base, trusted: trusted)
            } else { entries = nil }
            return .destination(.feed(source, entries))
        case .rss(let raw, let title, _):
            if let raw, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let target: RSSOpenTarget
                if trusted { target = try await RSSOpenTarget.rulePage(raw, source: source, owner: owner, context: request.context) }
                else {
                    let url = try Self.pageURL(raw, base: base)
                    guard SourceRequestHeaderScope.origin(url) == base.flatMap(SourceRequestHeaderScope.origin) else {
                        return .confirmation(.init(request: request, kind: .external(url), display: url.host ?? ""))
                    }
                    target = try await RSSOpenTarget.navigation(URLRequest(url: url), source: source, context: request.context, owner: owner)
                }
                return .destination(.web(source, target, title))
            }
            if let target = try await RSSOpenTarget.resolve(source: source, owner: owner) { return .destination(.web(source, target, title)) }
            return .destination(.feed(source, nil))
        case .login:
            guard source.loginUrl?.isEmpty == false || source.loginUi?.isEmpty == false else { throw RSSWebFailure.actionUnavailable }
            return .destination(.login(source))
        case .search(let query, let scope):
            let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !query.isEmpty, query.utf8.count <= 1_024 else { throw RSSWebFailure.actionUnavailable }
            return .destination(.search(query, scope))
        case .photo(let raw):
            let value = trusted ? raw : try Self.pageURL(raw, base: base).absoluteString
            return .destination(.photo(source, value, base, trusted, request.context))
        case .external(let url):
            guard RSSLinkRoute.route(url).url != nil else { throw RSSWebFailure.navigationBlocked }
            return .confirmation(.init(request: request, kind: .external(url), display: url.host ?? url.scheme ?? ""))
        case .addBook(let raw):
            await BookSourceStore.shared.waitUntilLoaded()
            let value = try await Self.bookRequest(raw, sources: BookSourceStore.shared.sources, base: base)
            return .confirmation(.init(request: request, kind: .book(value), display: value.source.bookSourceName))
        case .explore(let raw, let title, let origin):
            guard let origin else { throw RSSWebFailure.actionUnavailable }
            await BookSourceStore.shared.waitUntilLoaded()
            let sources = BookSourceStore.shared.sources
            guard let selected = await SourceScriptThread.run({ sources.first { $0.bookSourceUrl == origin } }) else { throw RSSWebFailure.actionUnavailable }
            let url = try Self.bookURL(raw, source: selected)
            return .confirmation(.init(request: request, kind: .explore(selected, url.absoluteString, title ?? selected.bookSourceName), display: selected.bookSourceName))
        case .playVideo(let raw, let title, let attachmentKey):
            if !trusted && !attachment {
                let target = try Self.pageURL(raw, base: base)
                guard SourceRequestHeaderScope.origin(target) == base.flatMap(SourceRequestHeaderScope.origin) else { throw RSSWebFailure.navigationBlocked }
            }
            let prepared = try await RSSMediaRequestService.prepare(raw, source: source,
                base: base, context: request.context, owner: owner, trustedRuleURL: trusted, article: request.article)
            try validate(request, owner: owner)
            let (stream, resources) = try await RSSMediaRequestService.stream(prepared)
            return .destination(.video(owner, prepared.context.article?.id, attachmentKey ?? "primary", stream, resources,
                                       title ?? prepared.context.article?.title ?? source.name))
        }
    }
    /// 远程网页数据必须作为URL字面量，不能成为AnalyzeUrl的模板/脚本/options。
    nonisolated static func pageURL(_ raw: String, base: URL?) throws -> URL {
        guard raw.utf8.count <= 32_768, let url = URL(string: raw, relativeTo: base)?.absoluteURL,
              SourceRequestHeaderScope.origin(url) != nil, url.user == nil, url.password == nil else { throw RSSWebFailure.navigationBlocked }
        let value = url.absoluteString.replacingOccurrences(of: "{", with: "%7B").replacingOccurrences(of: "}", with: "%7D")
        guard let literal = URL(string: value) else { throw RSSWebFailure.navigationBlocked }
        return literal
    }
    nonisolated static func sortEntries(_ raw: String, title: String?, base: URL?, trusted: Bool) async throws -> [RSSSortEntry] {
        try await SourceScriptThread.run {
            let entries = try LegadoSortURLParser.actionEntries(from: raw, title: title)
            guard entries.count <= 256 else { throw RSSWebFailure.actionUnavailable }
            return try entries.map { entry in
                if trusted { return entry }
                let url = try pageURL(entry.url, base: base)
                guard SourceRequestHeaderScope.origin(url) == base.flatMap(SourceRequestHeaderScope.origin) else { throw RSSWebFailure.navigationBlocked }
                return RSSSortEntry(name: entry.name, url: url.absoluteString)
            }
        }
    }
    /// 跨家族动作不能把RSS网页/脚本的options代码交给书源宿主，也不能向任意目标发送该书源认证。
    nonisolated static func bookURL(_ raw: String, source: BookSource) throws -> URL {
        guard !AnalyzeUrl.hasOptions(raw) else { throw RSSWebFailure.actionUnavailable }
        let base = URL(string: AnalyzeUrl.cleanBaseURL(source.bookSourceUrl))
        let url = try pageURL(raw, base: base)
        guard SourceRequestHeaderScope.origin(url) == base.flatMap(SourceRequestHeaderScope.origin) else { throw RSSWebFailure.navigationBlocked }
        return url
    }
    nonisolated static func bookRequest(_ raw: String, sources: [BookSource], base: URL?) async throws -> BookRequest {
        try await SourceScriptThread.run {
            try SourcePerfTrace.span("rss.web.bookSourceMatch", "main=\(Thread.isMainThread),sources=\(sources.count)") {
                let plain = AnalyzeUrl.stripOptions(from: raw)
                let suffix = String(raw.dropFirst(plain.count)).trimmingCharacters(in: .whitespacesAndNewlines)
                var origin: String?
                if !suffix.isEmpty {
                    guard let options = AnalyzeUrl.parseOptionDictionary(String(suffix.drop(while: { $0 == "," || $0.isWhitespace }))),
                          Set(options.keys) == ["origin"], let key = options["origin"] as? String else { throw RSSWebFailure.actionUnavailable }
                    origin = key
                }
                let url = try pageURL(plain, base: base)
                guard let selected = sources.first(where: { candidate in
                    candidate.enabled && (origin == nil || candidate.bookSourceUrl == origin)
                        && URL(string: AnalyzeUrl.cleanBaseURL(candidate.bookSourceUrl)).flatMap(SourceRequestHeaderScope.origin) == SourceRequestHeaderScope.origin(url)
                }) else { throw RSSWebFailure.actionUnavailable }
                return BookRequest(source: selected, url: try bookURL(url.absoluteString, source: selected).absoluteString)
            }
        }
    }
}
