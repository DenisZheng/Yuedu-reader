import Foundation
import JavaScriptCore

/// 网页只有明确的RSS动作，不获得解析器java的网络、文件或任意脚本执行能力。
enum RSSWebAction: Equatable, Sendable {
    case search(query: String, source: String?)
    case rss(url: String?, title: String?, origin: String?)
    case sort(url: String?, title: String?, origin: String?)
    case login(origin: String?)
    case photo(url: String)
    case addBook(url: String)
    case explore(url: String, title: String?, origin: String?)
    case external(URL)
    case playVideo(url: String, title: String?, attachmentKey: String?)
}

struct RSSWebActionRequest: Sendable {
    enum Authority: Equatable, Sendable { case sourceRule, page, attachment }
    var action: RSSWebAction
    var authority: Authority
    var sourceID: String
    var ownerID: String?
    var ticket: RSSRequestTicket?
    var baseURL: URL?
    var context: RSSOpenTarget.RequestContext? = nil
    var credentialRevision: UInt64 = 0
    var article: RSSOpenTarget.RequestContext.Article? = nil
}

enum RSSWebFailure: LocalizedError {
    case actionUnavailable, navigationBlocked, formBodyUnavailable, resourceRuleUnsupported, resourceUnavailable, imageFormatRestricted, viewportUnavailable
    var errorDescription: String? {
        switch self {
        case .actionUnavailable: localized("此網頁操作尚不支援")
        case .navigationBlocked: localized("此網頁跳轉已被安全限制阻擋")
        case .formBodyUnavailable: localized("無法安全重送此網頁表單，請使用網站登入入口")
        case .resourceRuleUnsupported: localized("此來源的資源規則無法安全執行")
        case .resourceUnavailable: localized("來源資源載入失敗")
        case .viewportUnavailable: localized("無法調整網頁縮放")
        case .imageFormatRestricted: localized("此圖片格式（SVG）無法在原生檢視器顯示，請在網頁中檢視")
        }
    }
}

@objc protocol RSSWebActionScriptExport: JSExport {
    func get(_ key: String) -> String
    func put(_ key: String, _ value: String) -> String
    func open(_ name: String, _ url: JSValue?, _ title: JSValue?, _ origin: JSValue?)
    func searchBook(_ query: String, _ scope: JSValue?)
    func showPhoto(_ url: String)
    func addBook(_ url: String)
    func playVideo(_ url: String, _ title: JSValue?)
}

/// 只在SourceScriptHost上使用；先收集动作，脚本成功且请求票据仍有效后才交给原生UI。
final class RSSWebActionScriptObject: NSObject, RSSWebActionScriptExport {
    private let state: RSSRuntimeState
    private let authenticationKey: String
    private(set) var actions: [RSSWebAction] = []
    private(set) var rejected = false
    init(runtime: RSSRuntime) { state = runtime.state; authenticationKey = RSSRuntime.authenticationKey(for: runtime.source) }
    func get(_ key: String) -> String {
        guard state.isCurrent, key.utf8.count <= 256 else { rejected = true; return "" }
        return state.sourceValue(for: authenticationKey, key: key) ?? ""
    }
    func put(_ key: String, _ value: String) -> String {
        guard state.isCurrent, key.utf8.count <= 256, value.utf8.count <= 65_536 else { rejected = true; return "" }
        state.setSourceValue(value, for: authenticationKey, key: key)
        return value
    }
    private func string(_ value: JSValue?) -> String? {
        guard let value, !value.isNull, !value.isUndefined else { return nil }
        guard value.isString, let text = value.toString(), text.utf8.count <= 32_768 else { rejected = true; return nil }
        return text
    }
    private func append(_ action: RSSWebAction) {
        guard state.isCurrent, !rejected, actions.count < 1 else { rejected = true; return }
        actions.append(action)
    }
    func searchBook(_ query: String, _ scope: JSValue?) {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, query.utf8.count <= 1_024 else { rejected = true; return }
        append(.search(query: query, source: string(scope)))
    }
    func showPhoto(_ url: String) { if url.utf8.count <= 32_768 { append(.photo(url: url)) } else { rejected = true } }
    func playVideo(_ url: String, _ title: JSValue?) {
        guard url.utf8.count <= 32_768 else { rejected = true; return }
        append(.playVideo(url: url, title: string(title), attachmentKey: nil))
    }
    func addBook(_ url: String) { if url.utf8.count <= 32_768 { append(.addBook(url: url)) } else { rejected = true } }
    func open(_ name: String, _ url: JSValue?, _ title: JSValue?, _ origin: JSValue?) {
        let url = string(url), title = string(title), origin = string(origin)
        switch name {
        case "rss": append(.rss(url: url, title: title, origin: origin))
        case "sort": append(.sort(url: url, title: title, origin: origin))
        case "login": append(.login(origin: origin))
        case "search":
            guard let title else { rejected = true; return }
            append(.search(query: title, source: origin))
        case "explore":
            guard let url else { rejected = true; return }
            append(.explore(url: url, title: title, origin: origin))
        default: rejected = true
        }
    }
}

enum RSSWebNavigation {
    struct Decision: Sendable {
        var intercepted: Bool
        var actions: [RSSWebAction]
    }
    /// Android String.isTrue的合同，不把字符串"false"按Swift非空字符串解释为true。
    static func isTrue(_ value: String) -> Bool {
        !["", "null", "false", "no", "not", "0", "0.0"].contains(value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }
    static func intercept(_ url: URL, source: RSSSource, context: RSSOpenTarget.RequestContext?, owner: RSSStore?) async throws -> Decision {
        guard let script = source.shouldOverrideUrlLoading, !script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .init(intercepted: false, actions: [])
        }
        let runtime = try await RSSRuntime.make(source: source, owner: owner)
        return try await runtime.run { host in
            try await host.run { bridge in
                let data = RuleData(); data.variableMap = context?.variables ?? [:]
                let actions = RSSWebActionScriptObject(runtime: runtime)
                var bindings: [String: Any] = ["url": url.absoluteString, "java": actions]
                if let info = context?.article {
                    let article = RSSArticleScriptObject(source: source, sortName: info.category, data: data)
                    article.title = info.title; article.link = info.link
                    bindings["rssArticle"] = article
                }
                let value = try bridge.withRuleContext(content: "", baseURL: url.absoluteString, scope: data,
                                                       bindings: bindings, stage: "rss.navigation") {
                    $0.getString(ruleStr: "@js:" + script)
                }
                guard !actions.rejected else { throw RSSWebFailure.actionUnavailable }
                return .init(intercepted: isTrue(value), actions: actions.actions)
            }
        }
    }
}
