import Foundation
import Testing
@testable import yuedu_app

@Suite("Legado LoginUiV2", .serialized)
@MainActor
struct LoginUiV2Tests {
    nonisolated static let mainJs = """
    const config = {bookSourceUrl:"https://login-v2-fixture.invalid",bookSourceName:"合成登录源"};
    function search(key,page){return [];}
    function getChapters(book){return [];}
    function getContent(chapter,book){return "正文";}
    function loginUi(state){return {rows:[{type:"label",name:"合成表单"}]};}
    function loginAction(action,state,form){return {close:true};}
    """

    @Test("导入成对 V2 函数生成登录标记，不要求旧 login 函数")
    func importsDynamicMainJsLogin() async throws {
        let source = try await Task.detached { try MainJsSource.extract(Self.mainJs) }.value
        #expect(source.loginUi == #"{"version":2}"#)
        #expect(source.loginUrl.isEmpty && source.hasLoginEntry)
        let form = try await SourceLoginUiV2Service(target: .book(source)).load()
        #expect(form.rows.map(\.name) == ["合成表单"])
    }

    @Test("主脚本拒绝不配对的 V2 函数和静态配置冲突")
    func rejectsInvalidMainJsLogin() async {
        let missing = Self.mainJs.replacingOccurrences(of: "function loginAction(action,state,form){return {close:true};}", with: "")
        await #expect(throws: MainJsSource.Failure.self) {
            try await Task.detached { try MainJsSource.extract(missing) }.value
        }
        let conflict = Self.mainJs.replacingOccurrences(of: "bookSourceName:", with: "loginUi:[{name:'legacy'}],bookSourceName:")
        await #expect(throws: MainJsSource.Failure.self) {
            try await Task.detached { try MainJsSource.extract(conflict) }.value
        }
    }

    nonisolated static let definition = """
    @js:function loginUi(state) {
      if (state.broken) return {rows: []};
      return {rows:[
        {type:'label',name:state.step === 2 ? '合成第二步' : '合成第一步'},
        {type:'text',name:'合成名称',key:'handle',hint:'字段提示',value:state.step === 2 ? 'normalized' : null},
        {type:'password',name:'合成口令',key:'pin'},
        {type:'select',name:'合成选项',key:'mode',options:['one','two']},
        {type:'toggle',name:'合成开关',key:'enabled',action:'switch',value:'false'},
        {type:'button',name:'下一步',action:'next',countdown:10},
        {type:'button',name:'提交',action:'save'},
        {type:'button',name:'失败例',action:'invalid'},
        {type:'button',name:'重绘失败例',action:'broken'}
      ]};
    }
    function loginAction(action,state,form) {
      if(action==='switch') return form.enabled === 'true' ? {state:{step:2}} : {};
      if(action==='next') {
        if(form.pin !== 'fixture-input') return {error:{pin:'合成错误'}};
        return {state:{step:2},future:'ignored'};
      }
      if(action==='save') {
        if(state.step !== 2 || form.handle !== 'normalized' || form.mode !== 'two') return {error:{handle:'步骤与字段必须对应'}};
        return {login:{handle:form.handle},close:true};
      }
      if(action==='invalid') return {login:{handle:'must-not-store'},close:1};
      if(action==='broken') return {state:{broken:true}};
      return null;
    }
    """

    @Test("声明式书源重绘、字段错误、显式登录和关闭沿同一宿主执行")
    func bookLogin() async throws {
        var source = BookSource(bookSourceUrl: "https://login-" + UUID().uuidString.lowercased() + ".invalid", bookSourceName: "合成源")
        source.loginUi = LoginUiV2.marker; source.loginUrl = Self.definition
        let key = source.bookSourceUrl
        defer { LoginManager.shared.clearLogin(sourceUrl: key) }
        let service = SourceLoginUiV2Service(target: .book(source))
        let initial = try await service.load()
        let mode = try #require(initial.rows.first { $0.key == "mode" })
        #expect(mode.resolve(edited: "invalid", stored: nil) == "one")
        #expect(initial.rows.first { $0.action == "next" }?.countdown == 10)
        var form = ["handle":"edited", "pin":"wrong-fixture", "mode":"two", "enabled":"false"]
        let rejected = try await service.perform("next", in: initial, form: form)
        #expect(rejected.errors == ["pin":"合成错误"] && !rejected.close)
        #expect(LoginManager.shared.getLoginInfo(sourceUrl: key) == nil)
        await #expect(throws: LoginUiV2.Failure.action) { try await service.perform("invalid", in: initial, form: form) }
        #expect(LoginManager.shared.getLoginInfo(sourceUrl: key) == nil)
        let broken = try await service.perform("broken", in: initial, form: form)
        #expect(broken.renderFailure == .render && broken.snapshot.state == initial.state && !broken.rerendered)
        form["pin"] = "fixture-input"
        let step = try await service.perform("next", in: initial, form: form)
        let handle = try #require(step.snapshot.rows.first { $0.key == "handle" })
        #expect(step.rerendered && step.snapshot.rows.first?.name == "合成第二步")
        #expect(handle.resolve(edited: "draft", stored: "stored") == "normalized")
        #expect(LoginManager.shared.getLoginInfo(sourceUrl: key) == nil)
        form["handle"] = "normalized"
        let finished = try await service.perform("save", in: step.snapshot, form: form)
        #expect(finished.close && finished.credentialsChanged)
        #expect(LoginManager.shared.getLoginInfo(sourceUrl: key) == ["handle":"normalized"])
        await #expect(throws: LoginUiV2.Failure.invalidated) { try await service.perform("save", in: step.snapshot, form: form) }
    }

    @Test("RSS 通过自己的源宿主执行 V2 并只写自己的 Keychain 项")
    func rssLoginAndOldRevision() async throws {
        let directory = URL.temporaryDirectory.appendingPathComponent("rss-v2-" + UUID().uuidString)
        let owner = RSSStore(storageDirectory: directory)
        var source = RSSSource(name: "合成 RSS V2", url: "https://rss-login-" + UUID().uuidString.lowercased() + ".invalid")
        source.loginUi = LoginUiV2.marker; source.loginUrl = Self.definition
        owner.addSource(source)
        let key = RSSRuntime.authenticationKey(for: source)
        defer { LoginManager.shared.clearLogin(sourceUrl: key) }
        let service = SourceLoginUiV2Service(target: .rss(source, owner))
        let initial = try await service.load()
        let form = ["handle":"normalized", "pin":"", "mode":"two", "enabled":"true"]
        let step = try await service.perform("switch", in: initial, form: form)
        #expect(step.rerendered && step.snapshot.rows.first?.name == "合成第二步")
        #expect(LoginManager.shared.getLoginInfo(sourceUrl: key) == nil)
        let saved = try await service.perform("save", in: step.snapshot, form: form)
        #expect(saved.close && LoginManager.shared.getLoginInfo(sourceUrl: key) == ["handle":"normalized"])
        #expect(LoginManager.shared.getLoginInfo(sourceUrl: source.sourceKey) == nil)
        let beforeChange = try await service.load()
        var modified = source; modified.name += " changed"; owner.updateSource(modified)
        await #expect(throws: CancellationError.self) { try await service.perform("save", in: beforeChange, form: form) }
    }

    @Test("变更书源时旧 V2 面板动作不能重建成旧配置")
    func doesNotRestoreInvalidBookSession() async throws {
        var source = BookSource(bookSourceUrl: "https://old-login-" + UUID().uuidString.lowercased() + ".invalid", bookSourceName: "合成源版本")
        source.loginUi = LoginUiV2.marker; source.loginUrl = Self.definition
        let service = SourceLoginUiV2Service(target: .book(source))
        let initial = try await service.load()
        source.loginUrl = source.loginUrl + "\n// configuration changed"
        BookSourceSession.invalidateMainJsSessions(previous: [source.id: 0], current: [source], positions: [source.id: 0])
        await #expect(throws: LoginUiV2.Failure.invalidated) {
            try await service.perform("switch", in: initial, form: ["handle":"", "pin":"", "mode":"one", "enabled":"true"])
        }
    }

    @Test("结果只接受 V2 行与类型正确的已知命令，验证重复键及上限")
    func validatesProtocol() throws {
        let invalidRows = [#"{"rows":[]}"#, #"{"rows":[{"name":"X","key":"dupe"},{"name":"Y","key":"dupe"}]}"#,
                           #"{"rows":[{"name":"X","type":"toggle","key":"a","value":"yes"}]}"#,
                           #"{"rows":[{"name":"X","type":"button","action":"s","countdown":-1}]}"#]
        for body in invalidRows { #expect(throws: LoginUiV2.Failure.render) { try LoginUiV2.rows(body) } }
        #expect(throws: LoginUiV2.Failure.action) { try LoginUiV2.command(#"{"error":[],"login":{"ignored":"invalid"}}"#) }
        #expect(throws: LoginUiV2.Failure.action) { try LoginUiV2.command(#"{"state":"{}"}"#) }
        #expect(throws: LoginUiV2.Failure.limit) { try LoginUiV2.rows(String(repeating: " ", count: LoginUiV2.byteLimit + 1)) }
        let noop = try LoginUiV2.command(#"{"unknown":1,"state":null,"close":null}"#)
        #expect(noop == LoginUiV2.Command())
    }
}
