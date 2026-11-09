import Foundation
import Testing
@testable import yuedu_app

@Suite("RSS owned login service", .serialized)
@MainActor struct RSSLoginServiceTests {
    @Test("loginUrl函数先于动态loginUi、viewName；复用同一RSS宿主并使用独立凭据")
    func dynamicFormAndAction() async throws {
        try await fixture { owner, source in
            let snapshot = try await RSSLoginService.load(source: source, owner: owner)
            #expect(snapshot.fields.map(\.name) == ["user", "password", "flag"])
            #expect(snapshot.labels["user"] == "User synthetic")
            #expect(snapshot.values["flag"] == nil, "toggle默认值只用于显示，不能隐式写入")
            let result = try await RSSLoginService.perform(source: source, owner: owner,
                values: ["user": "synthetic-user", "password": "synthetic-password"], action: nil, login: true)
            #expect(result.actions.isEmpty)
            let key = RSSRuntime.authenticationKey(for: source)
            #expect(LoginManager.shared.getLoginInfo(sourceUrl: key)?["user"] == "synthetic-user")
            #expect(LoginManager.shared.getLoginHeader(sourceUrl: key)?.contains("synthetic-user") == true)
            #expect(LoginManager.shared.getLoginHeader(sourceUrl: source.sourceKey) == nil)
            let changed = try await RSSLoginService.load(source: source, owner: owner)
            #expect(changed.values["user"] == "synthetic-user")
        }
    }
    @Test("菜单java.get/put属于源，其他java网络方法保留；动作只收集到成功结果")
    func nativeMenuKeepsNetworkJava() async throws {
        try await fixture { owner, source in
            _ = try await RSSLoginService.perform(source: source, owner: owner, values: [:],
                action: "if(typeof java.ajax!=='function')throw Error('missing');java.put('menu','selected');java.open('sort','/list','List')")
            #expect(owner.variables(for: source.id)["menu"] == "selected")
            do {
                _ = try await RSSLoginService.perform(source: source, owner: owner, values: [:],
                    action: "java.open('sort','/list','List');throw Error('private-synthetic-error')")
                Issue.record("异常菜单不应返回成功动作")
            } catch { #expect(!error.localizedDescription.contains("private-synthetic-error")) }
        }
    }
    @Test("startBrowserAwait与验证码交互的允许范围限于前台登录，并释放同源源脚本队列")
    func loginInteractionCompletesScript() async throws {
        try await fixture { owner, source in
            let runtime = try await RSSRuntime.make(source: source, owner: owner)
            let handlers = SourceUserInterfaceHandlers(
                browser: { active, request, completion in
                    guard active.state.isCurrent, request.awaitsResult else { completion(nil); return }
                    completion("<p>synthetic challenge complete</p>")
                },
                captcha: { active, request, completion in
                    guard active.state.isCurrent, request.sourceURL == source.sourceKey else { completion(nil); return }
                    completion("synthetic-code")
                },
                browserPage: { _, _ in }
            )
            let browser = try await RSSLoginService.perform(source: source, owner: owner, values: [:],
                action: "var r=java.startBrowserAwait('https://login.invalid/check','Check',false);java.put('browser',r.body());java.get('browser')",
                interactions: handlers)
            #expect(browser.actions.isEmpty)
            let persisted = try await RSSRuntime.make(source: source, owner: owner)
            #expect(persisted.state.sourceValue(for: RSSRuntime.authenticationKey(for: source), key: "browser") == "<p>synthetic challenge complete</p>")
            _ = try await RSSLoginService.perform(source: source, owner: owner, values: [:],
                action: "java.put('captcha',java.getVerificationCode('https://login.invalid/captcha'))",
                interactions: handlers)
            let afterCaptcha = try await RSSRuntime.make(source: source, owner: owner)
            #expect(afterCaptcha.state.sourceValue(for: RSSRuntime.authenticationKey(for: source), key: "captcha") == "synthetic-code")
        }
    }

    @Test("配置变化后旧登录source拒收；无静默空表单或新JSContext回退")
    func invalidSourceAndUI() async throws {
        try await fixture { owner, source in
            var modified = source
            modified.name += " updated"
            owner.updateSource(modified)
            do { _ = try await RSSLoginService.load(source: source, owner: owner); Issue.record("旧配置未拒绝") }
            catch { #expect(error is CancellationError) }
            modified.loginUi = "@js:'not-json'"
            owner.updateSource(modified)
            do { _ = try await RSSLoginService.load(source: modified, owner: owner); Issue.record("坏UI未报错") }
            catch { #expect(!(error is CancellationError)) }
        }
    }
    private func fixture(_ run: (RSSStore, RSSSource) async throws -> Void) async throws {
        let directory = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let owner = RSSStore(storageDirectory: directory)
        var source = RSSSource(name: "Synthetic RSS login", url: "https://login-" + UUID().uuidString.lowercased() + ".invalid")
        source.loginUrl = """
            @js:function label(){return 'User synthetic'}
            function menu(){return JSON.stringify([{name:'user',viewName:'label()',type:'text'},{name:'password',type:'password'},{name:'flag',type:'toggle',chars:['off','on'],default:'off'}])}
            function login(){var info=source.getLoginInfoMap();source.putLoginHeader(JSON.stringify({Authorization:info.get('user')}))}
            """
        source.loginUi = "@js:menu()"
        owner.addSource(source)
        defer {
            LoginManager.shared.clearLogin(sourceUrl: RSSRuntime.authenticationKey(for: source))
            do { try FileManager.default.removeItem(at: directory) } catch { Issue.record(error) }
        }
        do { try await run(owner, source) }
        catch { try await owner.flushPersistence(); throw error }
        try await owner.flushPersistence()
    }
}
