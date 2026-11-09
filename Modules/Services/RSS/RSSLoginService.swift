import Foundation

/// 登录沿RSS自己的共享宿主和凭据命名空间执行；不借用BookSource或创建登录专用JSContext。
enum RSSLoginService {
    struct Snapshot: Sendable {
        var fields: [LoginField]
        var labels: [String: String]
        var values: [String: String]
        var webTarget: RSSOpenTarget?
        var canLogin: Bool = false
    }
    struct Result: Sendable {
        var actions: [RSSWebAction]
        var webTarget: RSSOpenTarget?
    }
    private static func bound(_ handlers: SourceUserInterfaceHandlers, to runtime: RSSRuntime) -> BoundSourceUserInterfaceHandlers {
        BoundSourceUserInterfaceHandlers(
            browser: { request, completion in handlers.browser(runtime, request, completion) },
            captcha: { request, completion in handlers.captcha(runtime, request, completion) },
            browserPage: { request in handlers.browserPage(runtime, request) }
        )
    }

    nonisolated static func load(source: RSSSource, owner: RSSStore, interactions: SourceUserInterfaceHandlers? = nil) async throws -> Snapshot {
        let ui = (source.loginUi ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let login = source.loginUrl ?? ""
        guard !ui.isEmpty || !login.isEmpty else { throw RSSWebFailure.actionUnavailable }
        let runtime = try await RSSRuntime.make(source: source, owner: owner)
        if ui.isEmpty, LoginManager.shared.extractLoginJs(login) == nil {
            let target = try await RSSOpenTarget.rulePage(login, source: source, owner: owner)
            return Snapshot(fields: [], labels: [:], values: [:], webTarget: target)
        }
        return try await runtime.run { host in
            try await host.run { bridge in
                let values = LoginManager.shared.getLoginInfo(sourceUrl: RSSRuntime.authenticationKey(for: source)) ?? [:]
                let api = RSSWebActionScriptObject(runtime: runtime)
                let java = try bridge.userInterfaceJava(api, methods: ["get", "put", "open", "searchBook", "showPhoto", "addBook"])
                var bindings: [String: Any] = ["result": values, "book": NSNull(), "chapter": NSNull(), "java": java]
                let definitions = LoginManager.shared.extractLoginJs(login) ?? ""
                let expression = LoginManager.shared.extractLoginJs(ui)
                let body = ui.isEmpty ? "'[]'" : expression ?? "JSON.stringify((" + ui + "))"
                let handlers = interactions.map { Self.bound($0, to: runtime) }
                let json = try bridge.withUserInterface(handlers) { try bridge.withRuleContext(content: "", baseURL: source.sourceKey, scope: nil, bindings: bindings, stage: "rss.login.ui") {
                    $0.getString(ruleStr: "@js:" + definitions + "\n" + body)
                } }
                // json已经由同一源宿主规范化，避免旧lenient解析器另建临时JSContext。
                guard let object = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: Any]],
                      object.count <= 256, let fields = LoginManager.shared.parseLoginUiResult(json),
                      Set(fields.map(\.name)).count == fields.count, !api.rejected else { throw RSSWebFailure.actionUnavailable }
                var resolved = values, labels = fields.literalViewNames
                for field in fields {
                    if field.type != .toggle, resolved[field.name] == nil, let value = field.defaultValue { resolved[field.name] = value }
                    if field.type == .select, resolved[field.name] == nil, let first = field.options.first { resolved[field.name] = first }
                    if field.hasDynamicViewName, let expression = field.viewName {
                        bindings["result"] = values
                        let label = try bridge.withRuleContext(content: "", baseURL: source.sourceKey, scope: nil, bindings: bindings, stage: "rss.login.label") {
                            $0.getString(ruleStr: "@js:" + definitions + "\n" + expression)
                        }
                        labels[field.name] = String(label.prefix(256))
                    }
                }
                return Snapshot(fields: fields, labels: labels, values: resolved, webTarget: nil, canLogin: !definitions.isEmpty)
            }
        }
    }

    nonisolated static func perform(source: RSSSource, owner: RSSStore, values: [String: String], action: String?, login: Bool = false, interactions: SourceUserInterfaceHandlers? = nil) async throws -> Result {
        let runtime = try await RSSRuntime.make(source: source, owner: owner)
        guard values.count <= 256, values.values.allSatisfy({ $0.utf8.count <= 65_536 }) else { throw RSSWebFailure.actionUnavailable }
        try await SourceScriptThread.run {
            runtime.state.mutateCredentials {
                LoginManager.shared.storeLoginInfo(sourceUrl: RSSRuntime.authenticationKey(for: source), info: values, expectedRevision: $0)
            }
            guard runtime.state.isCurrent else { throw CancellationError() }
        }
        if let action, action.hasPrefix("https://") || action.hasPrefix("http://") {
            return Result(actions: [], webTarget: try await RSSOpenTarget.rulePage(action, source: source, owner: owner))
        }
        guard login || action?.isEmpty == false else { return Result(actions: [], webTarget: nil) }
        return try await runtime.run { host in
            try await host.run { bridge in
                let api = RSSWebActionScriptObject(runtime: runtime)
                let java = try bridge.userInterfaceJava(api, methods: ["get", "put", "open", "searchBook", "showPhoto", "addBook"])
                let definitions = LoginManager.shared.extractLoginJs(source.loginUrl ?? "") ?? ""
                let body = login ? "if(typeof login!=='function')throw new Error('Source login function missing');login();" : LoginManager.shared.extractLoginJs(action ?? "") ?? action ?? ""
                let handlers = interactions.map { Self.bound($0, to: runtime) }
                let result = try bridge.withUserInterface(handlers) { try bridge.withRuleContext(content: "", baseURL: source.sourceKey, scope: nil,
                    bindings: ["java": java, "result": values, "book": NSNull(), "chapter": NSNull()], stage: "rss.login.action") {
                    $0.getString(ruleStr: "@js:" + definitions + "\n" + body)
                } }
                guard !api.rejected else { throw RSSWebFailure.actionUnavailable }
                if login, result.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("{") {
                    guard let headers = try JSONSerialization.jsonObject(with: Data(result.utf8)) as? [String: String] else { throw RSSWebFailure.actionUnavailable }
                    let raw = String(decoding: try JSONSerialization.data(withJSONObject: headers), as: UTF8.self)
                    runtime.state.mutateCredentials { LoginManager.shared.storeLoginHeader(sourceUrl: RSSRuntime.authenticationKey(for: source), raw: raw, expectedRevision: $0) }
                }
                return Result(actions: api.actions, webTarget: nil)
            }
        }
    }
}
