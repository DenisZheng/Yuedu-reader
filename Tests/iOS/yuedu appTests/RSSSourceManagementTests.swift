import Foundation
import Testing
@testable import yuedu_app

@Suite("RSS source management and debugger", .serialized)
@MainActor struct RSSSourceManagementTests {
    @Test("Legado JSON编辑：保留本地身份/排序，拒绝重复网址与坏JSON；保存使旧请求票据失效")
    func jsonEditing() async throws {
        try await withStore { store in
            var source = RSSSource(name: "Edit", url: "https://edit-fixture.invalid/rss")
            source.ruleArticles = "class.a"; source.importedFromLegado = true
            let other = RSSSource(name: "Other", url: "https://other-fixture.invalid/rss")
            let added = store.addSourcesReturningAdded([source, other])
            let current = try #require(added.first)
            let ticket = try #require(store.requestTicket(for: current.id))
            var json = try LegadoSourceJSONParser.exportJSON(from: current)
            json["ruleArticles"] = "class.b"; json["sourceName"] = "Edited"
            let text = String(decoding: try JSONSerialization.data(withJSONObject: json), as: UTF8.self)
            let edited = try RSSSourceJSONEditor.apply(text, to: current, others: store.sources)
            #expect(edited.id == current.id && edited.sortOrder == current.sortOrder)
            #expect(edited.ruleArticles == "class.b" && edited.name == "Edited")
            store.updateSource(edited)
            #expect(!store.accepts(ticket), "配置修订后旧请求不得再写回")
            #expect(store.source(id: current.id)?.ruleArticles == "class.b")

            json["sourceUrl"] = other.url
            let duplicate = String(decoding: try JSONSerialization.data(withJSONObject: json), as: UTF8.self)
            #expect(throws: RSSSourceEditFailure.self) { try RSSSourceJSONEditor.apply(duplicate, to: edited, others: store.sources) }
            #expect(throws: RSSSourceEditFailure.self) { try RSSSourceJSONEditor.apply("{", to: edited, others: store.sources) }
            #expect(throws: RSSSourceEditFailure.self) { try RSSSourceJSONEditor.apply("[]", to: edited, others: store.sources) }
        }
    }

    @Test("源变量编辑与脚本共享同一份：落盘重载仍在，并使旧票据失效")
    func variableEditing() async throws {
        let directory = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { do { try FileManager.default.removeItem(at: directory) } catch { Issue.record(error) } }
        let store = RSSStore(storageDirectory: directory)
        let source = try #require(store.addSourcesReturningAdded([RSSSource(name: "Var", url: "https://var-fixture.invalid/rss")]).first)
        let ticket = try #require(store.requestTicket(for: source.id))
        try store.setSourceVariableJSON(#"{"token":"local"}"#, for: source.id)
        #expect(!store.accepts(ticket))
        #expect(try store.runtimeSnapshot(for: source).variableJSON == #"{"token":"local"}"#)
        try await store.flushPersistence()
        let reloaded = RSSStore(storageDirectory: directory)
        let again = try #require(reloaded.source(id: source.id))
        #expect(try reloaded.runtimeSnapshot(for: again).variableJSON == #"{"token":"local"}"#)
    }

    @Test("调试走生产列表/正文路径：显示数量与分页轨迹，网址去查询，不泄露标题/正文/凭据")
    func debuggerTrace() async throws {
        let server = try VideoStillFixtureServer(directory: URL.temporaryDirectory, routes: [
            "/list": .init(body: Data("<div class='i'><a href='/post?id=7&token=secret'>Secret title</a></div><a id='n' href='/list?page=2&token=secret'>n</a>".utf8)),
            "/post": .init(body: Data("<div id='c'>Private body text</div>".utf8)),
            "/broken": .init(body: Data(), status: "500 Internal Server Error")
        ])
        let base = try await server.start()
        defer { server.stop() }
        try await withStore { store in
            var source = RSSSource(name: "Debug", url: base.appendingPathComponent("list").absoluteString + "?token=secret")
            source.importedFromLegado = true
            source.ruleArticles = "class.i"; source.ruleTitle = "tag.a@text"; source.ruleLink = "tag.a@href"
            source.ruleNextPage = "id.n@href"; source.ruleContent = "id.c@text"
            source = try #require(store.addSourcesReturningAdded([source]).first)
            let debugger = RSSSourceDebugger()
            debugger.start(source: source, key: "", owner: store)
            try await finish(debugger)
            let text = debugger.lines.map(\.text).joined(separator: "\n")
            #expect(text.contains(String(format: localized("條目數：%d"), 1)), "\(text)")
            #expect(text.contains(String(format: localized("下一頁：%@"), base.appendingPathComponent("list").absoluteString + "?…")), "\(text)")
            #expect(text.contains(String(format: localized("正文長度：%d"), "Private body text".count)))
            #expect(text.contains(localized("解析完成")))
            for leaked in ["secret", "Secret title", "Private body"] { #expect(!text.contains(leaked), "调试日志泄露：\(leaked)") }
            #expect(store.articles(for: source.id).isEmpty, "调试不写入文章")

            debugger.start(source: source, key: "坏::" + base.appendingPathComponent("broken").absoluteString, owner: store)
            try await finish(debugger)
            #expect(debugger.lines.last?.level == .failure)
            #expect(debugger.lines.last?.text.contains("500") == true)

            debugger.start(source: source, key: "keyword", owner: store)
            try await finish(debugger)
            #expect(debugger.lines.last?.text == localized("搜尋網址為空"))
        }
    }

    @Test("运行变量文件损坏时拒绝用户编辑，不能覆盖原文件")
    func corruptVariablesAreNotOverwritten() async throws {
        let directory = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { do { try FileManager.default.removeItem(at: directory) } catch { Issue.record(error) } }
        let source = RSSSource(name: "Unreadable", url: "https://unreadable.invalid")
        let initial = RSSStore(storageDirectory: directory)
        initial.addSource(source)
        try await initial.flushPersistence()
        let file = directory.appendingPathComponent("rss_runtime_variables.json")
        let invalid = Data("{broken".utf8)
        try invalid.write(to: file)
        let owner = RSSStore(storageDirectory: directory)
        #expect(throws: ScraperError.self) { try owner.setSourceVariableJSON("new-value", for: source.id) }
        #expect(try Data(contentsOf: file) == invalid)
    }

    @Test("规则与任意异常不得泄露脚本或凭据；调试重新开始不被旧任务提前置空")
    func debuggerPrivacyAndRestart() async throws {
        let marker = "private-fixture-marker"
        #expect(!RSSSourceDebugger.rule("@js: var account='" + marker + "'; result").contains(marker))
        #expect(!RSSSourceDebugger.describe(ScraperError.invalidRule(marker)).contains(marker))
        try await withStore { owner in
            let source = RSSSource(name: "Restart", url: "https://restart.invalid")
            owner.addSource(source)
            let debugger = RSSSourceDebugger()
            debugger.start(source: source, key: "first", owner: owner)
            debugger.start(source: source, key: "second", owner: owner)
            try await finish(debugger)
            #expect(debugger.lines.filter { $0.text == localized("開始解析") }.count == 1)
            #expect(debugger.lines.last?.text == localized("搜尋網址為空"))
        }
    }

    private func finish(_ debugger: RSSSourceDebugger) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while debugger.isRunning, ContinuousClock.now < deadline { await Task.yield() }
        try #require(!debugger.isRunning)
    }

    private func withStore(_ run: (RSSStore) async throws -> Void) async throws {
        let directory = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = RSSStore(storageDirectory: directory)
        defer { if FileManager.default.fileExists(atPath: directory.path) {
            do { try FileManager.default.removeItem(at: directory) } catch { Issue.record(error) } } }
        do { try await run(store) } catch { try await store.flushPersistence(); throw error }
        try await store.flushPersistence()
    }
}
