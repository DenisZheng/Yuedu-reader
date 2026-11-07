import Foundation
import Testing
@testable import yuedu_app

private final class RSSMemoryRuntimeState: SourceRuntimeStateAccess, @unchecked Sendable {
    private let lock = NSLock()
    private var json: String?
    private var values: [String: String] = [:]
    func sourceVariableJSON(for sourceUrl: String) -> String? { lock.withLock { json } }
    func setSourceVariableJSON(_ json: String?, for sourceUrl: String) { lock.withLock { self.json = json } }
    func sourceVariables(for sourceUrl: String) -> [String: Any] { [:] }
    func sourceValue(for sourceUrl: String, key: String) -> String? { lock.withLock { values[key] } }
    func setSourceValue(_ value: String, for sourceUrl: String, key: String) { lock.withLock { values[key] = value } }
}

@Suite("RSS shared bridge context", .serialized)
struct RSSSharedBridgeTests {
    @Test("RSS元数据与共同方法并存，书源同key不串源；jsLib只加载一次")
    func metadataAndSession() async throws {
        var source = BookSource(bookSourceUrl: "opaque#shared", bookSourceName: "RSS fixture")
        source.jsLib = "var count = 0;"
        let state = RSSMemoryRuntimeState()
        let overrides = SourceRuntimeOverrides(identity: UUID().uuidString, authenticationKey: "rss-fixture",
            propertiesJSON: Data(#"{"sourceUrl":"opaque#shared","sourceName":"RSS fixture","type":2,"ruleContent":"video@src"}"#.utf8), state: state)
        let session = BookSourceSession.session(for: source, runtimeOverrides: overrides)
        let same = BookSourceSession.session(for: source, runtimeOverrides: overrides)
        #expect(session === same)
        #expect(session !== BookSourceSession.session(for: source))
        let first = try await session.parse { bridge in
            try bridge.withRuleContext(content: "", baseURL: source.bookSourceUrl, scope: RuleData()) { engine in
                engine.getString(ruleStr: "@js: source.getKey() + '|' + source.getTag() + '|' + source.type + '|' + source.ruleContent + '|' + (++count)")
            }
        }
        let second = try await session.parse { bridge in
            try bridge.withRuleContext(content: "", baseURL: source.bookSourceUrl, scope: RuleData()) { engine in
                engine.getString(ruleStr: "@js: String(++count)")
            }
        }
        #expect(first == "opaque#shared|RSS fixture|2|video@src|1")
        #expect(second == "2")
    }

    @Test("RuleData和getString(mContent)/setContent回调实际生效")
    func ruleCallbacks() async throws {
        let source = BookSource(bookSourceUrl: "https://callback.invalid", bookSourceName: "Callback fixture")
        let session = BookSourceSession(source: source)
        let result = try await session.parse { bridge in
            let scope = RuleData()
            return try bridge.withRuleContext(content: "<b>Outer</b>", baseURL: source.bookSourceUrl, scope: scope) { engine in
                let first = engine.getString(ruleStr: "@js: java.put('article', java.getString('b@text')); java.getString('b@text', '<b>Inner</b>')")
                let second = engine.getString(ruleStr: "@js: java.get('article') + '|' + java.getString('b@text')")
                let third = engine.getString(ruleStr: "@js: java.setContent('<p>Set</p>'); java.getString('p@text')")
                return [first, second, third]
            }
        }
        #expect(result == ["Inner", "Outer|Outer", "Set"])
    }

    @Test("一个源的两篇文章变量彼此隔离，源变量连续")
    func scopedVariables() async throws {
        let source = BookSource(bookSourceUrl: "https://scope-\(UUID().uuidString).invalid", bookSourceName: "Scoped fixture")
        let session = BookSourceSession(source: source)
        async let a = session.parse { bridge in
            let scope = RuleData()
            scope.variableMap = ["name": "A"]
            return try bridge.withRuleContext(content: "", baseURL: source.bookSourceUrl, scope: scope) {
                $0.getString(ruleStr: "@js: java.put('local', java.get('name')); java.get('local')")
            }
        }
        async let b = session.parse { bridge in
            let scope = RuleData()
            scope.variableMap = ["name": "B"]
            return try bridge.withRuleContext(content: "", baseURL: source.bookSourceUrl, scope: scope) {
                $0.getString(ruleStr: "@js: java.put('local', java.get('name')); java.get('local')")
            }
        }
        let results = try await [a, b]
        #expect(results == ["A", "B"])
        let clean = try await session.parse { bridge in
            try bridge.withRuleContext(content: "", baseURL: source.bookSourceUrl, scope: RuleData()) {
                $0.getString(ruleStr: "@js: java.get('local')")
            }
        }
        #expect(clean.isEmpty)
    }
}
