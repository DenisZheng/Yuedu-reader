import Foundation
import Testing
import UIKit
@testable import yuedu_app

/// Replace rules run once, at display time, with one set of semantics. The online reader
/// used to carry its own copy of the replace loop that had drifted from
/// `ReplaceRuleEngine` (reported 2026-10-10), and the chapter fetcher also baked rules into
/// the cache, so plain-text online chapters got them twice.
@Suite("Replace rules at display time", .serialized)
struct ReplaceRuleDisplayTimeTests {

    private static func rule(_ pattern: String, _ replacement: String, regex: Bool = true) -> ReplaceRule {
        ReplaceRule(name: "ReplaceRuleDisplayTimeTests", pattern: pattern, replacement: replacement, isRegex: regex)
    }

    private static func attributed(_ text: String) -> NSMutableAttributedString {
        NSMutableAttributedString(string: text, attributes: [.foregroundColor: UIColor.red])
    }

    private func makeRuleDirectory() throws -> URL {
        let folder = URL.temporaryDirectory.appendingPathComponent("ReplaceRuleTest-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private func removeRuleDirectory(_ folder: URL) {
        do { try FileManager.default.removeItem(at: folder) }
        catch { Issue.record("无法清理本次规则测试目录") }
    }

    @Test("设置页文件预览不写入，确认只保存可支持的正文规则")
    @MainActor func reviewedMixedImportRequiresConfirmation() async throws {
        let folder = try makeRuleDirectory()
        defer { removeRuleDirectory(folder) }
        let input = folder.appendingPathComponent("import.json")
        try MixedReplaceRuleFixture.data.write(to: input)
        let output = folder.appendingPathComponent("replace.json")
        let store = ReplaceRuleStore(file: output)

        _ = try await ReplaceRuleImportParser.review(file: input) // 关闭预览，不调用保存。
        try await store.persistPendingChanges()
        #expect(store.revision == 0)
        #expect(store.rules.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: output.path))

        let review = try await ReplaceRuleImportParser.review(file: input)
        #expect(review.rows.map(\.id) == [1, 2, 3, 4])
        #expect(Array(review.rows.dropFirst().map(\.outcome)) == [
            .unsupported(["scopeTitle", "scopeContent"]), .unsupported(["excludeScope"]), .invalid(["scopeContent"])
        ])
        #expect(try await store.importConfirmedRules(review) == 1)
        let reloaded = ReplaceRuleStore(file: output)
        reloaded.reloadFromDisk()
        #expect(reloaded.rules.map(\.id) == ["legado:42"])
        #expect(ReplaceRuleEngine.apply(reloaded.rules, to: "噪声保留标题") == "保留标题")
        let revision = store.revision
        #expect(try await store.importConfirmedRules(review) == 1)
        #expect(store.revision == revision)
    }

    @Test("旧格式的空主字段不能盖掉非空替换别名；没有别名仍可删除", arguments: [true, false])
    @MainActor func manualLegacyReplacementAlias(hasAlias: Bool) async throws {
        let folder = try makeRuleDirectory()
        defer { removeRuleDirectory(folder) }
        let input = folder.appendingPathComponent("import.json")
        let json = hasAlias ? #"{"pattern":"A","replacement":"","replace":"B"}"# : #"{"pattern":"A","replacement":""}"#
        try Data(json.utf8).write(to: input)
        let store = ReplaceRuleStore(file: folder.appendingPathComponent("rules.json"))

        let review = try await ReplaceRuleImportParser.review(file: input)
        try #require(!review.hasIssues && review.rules.count == 1)
        try await store.importConfirmedRules(review)
        #expect(ReplaceRuleEngine.apply(store.rules, to: "A") == (hasAlias ? "B" : ""))
    }

    @Test("本地文件混合包逐条审查：保留完整源地址，不导入坏正则或非对象")
    @MainActor func manualReviewWithExactSourceAndBrokenRegex() async throws {
        let folder = try makeRuleDirectory()
        defer { removeRuleDirectory(folder) }
        let input = folder.appendingPathComponent("import.json")
        let scope = "https://news.example.invalid/feed?editions=morning,evening;late#day"
        let json = """
            [{"id":42,"pattern":"A","replacement":"B","scope":"\(scope)"},{"id":43,"pattern":"(","isRegex":true},null]
            """
        try Data(json.utf8).write(to: input)
        let store = ReplaceRuleStore(file: folder.appendingPathComponent("rules.json"))

        let review = try await ReplaceRuleImportParser.review(file: input)
        #expect(review.rows.map(\.id) == [1, 2, 3])
        #expect(review.rows.dropFirst().map(\.outcome) == [.invalid(["pattern"]), .invalid([])])
        #expect(store.revision == 0)
        #expect(try await store.importConfirmedRules(review) == 1)
        #expect(store.rules.map(\.scope) == [scope])
        let exact = ReplaceRuleStore.rules(for: scope, from: store.rules)
        let truncated = ReplaceRuleStore.rules(for: "https://news.example.invalid/feed?editions=morning", from: store.rules)
        #expect(ReplaceRuleEngine.apply(exact, to: "A") == "B")
        #expect(ReplaceRuleEngine.apply(truncated, to: "A") == "A")
    }

    @Test("手动预览遇到嵌套歧义不能确认部分保存", arguments: [
        #"[{"pattern":"A"},{"data":{"rules":[],"data":[]}}]"#,
        #"{"replaceRuleList":[{"pattern":"A"},[{"data":{"rules":[],"data":[]}}]]}"#
    ])
    @MainActor func manualReviewRefusesNestedAmbiguity(json: String) async throws {
        let folder = try makeRuleDirectory()
        defer { removeRuleDirectory(folder) }
        let input = folder.appendingPathComponent("import.json")
        try Data(json.utf8).write(to: input)
        let output = folder.appendingPathComponent("rules.json")
        let store = ReplaceRuleStore(file: output)

        await #expect(throws: ReplaceRuleImportError.ambiguousPack) {
            let review = try await ReplaceRuleImportParser.review(file: input)
            if !review.rules.isEmpty {
                // 模拟预览上仍可点击的确认操作：错误实现会真的写入。
                try await store.importConfirmedRules(review)
            }
        }
        #expect(store.rules.isEmpty && store.revision == 0)
        #expect(!FileManager.default.fileExists(atPath: output.path))
    }

    @Test("旧文件与新导入的范围只在完整目标地址生效", arguments: [
        ("https://a.example.invalid/feed", ",\n "),
        ("https://a.example.invalid/feed?editions=morning,evening", ";"),
        ("https://a.invalid", ",,"),
        ("https://a.invalid:8443", "；,\r\n"),
        ("https://a.invalid/?v=x,", ";"),
        ("https://a.invalid/?v=x,", " \n; ,"),
        ("https://a.invalid/feed,", ";"),
        ("https://a.invalid/#part;", ","),
        ("https://a.invalid/?q=x,http://", ""),
        ("https://a.invalid/?q=x,http://", ";")
    ])
    @MainActor func sourceScopeListActuallyReplaces(first: String, separator: String) async throws {
        let folder = try makeRuleDirectory()
        defer { removeRuleDirectory(folder) }
        let second = "https://b.example.invalid/feed"
        let targets = separator.isEmpty ? [first] : [first, second]
        let scope = targets.joined(separator: separator)
        let original = ReplaceRule(id: "rule-list", name: "列表规则", pattern: "A", replacement: "B", scope: scope)
        let file = folder.appendingPathComponent("rules.json")
        try JSONEncoder().encode([original]).write(to: file)
        let store = ReplaceRuleStore(file: file)
        store.reloadFromDisk()

        func text(from source: String) -> String {
            let applicable = ReplaceRuleStore.rules(for: source, from: store.rules)
            return ReplaceRuleEngine.apply(applicable, to: "A")
        }
        let nonTargets = ["https://a.example.invalid/feed?editions=morning", "https://a.invalid/?v=x",
                          "https://a.invalid/?q=x", "https://a.invalid/feed", "https://a.invalid/#part",
                          "https://unrelated.example.invalid", ""] + (separator.isEmpty ? [] : [scope])
        for source in targets { #expect(text(from: source) == "B") }
        for source in nonTargets { #expect(text(from: source) == "A") }

        let update = try JSONSerialization.data(withJSONObject: [
            "id": original.id, "pattern": "A", "replacement": "C", "scope": scope
        ])
        let input = folder.appendingPathComponent("import.json")
        try update.write(to: input)
        let review = try await ReplaceRuleImportParser.review(file: input)
        try #require(!review.hasIssues)
        #expect(try await store.importConfirmedRules(review) == 1)
        #expect(store.rules.first?.scope == scope)
        for source in targets { #expect(text(from: source) == "C") }
        for source in nonTargets { #expect(text(from: source) == "A") }
    }

    @Test("生产规则选择先排除停用与无关源，再按顺序实际替换")
    func readerRuleSelectionFiltersAndSorts() {
        let source = "https://a.invalid/?v=x,"
        let rules = [
            ReplaceRule(id: "second", name: "后执行", pattern: "B", replacement: "C", scope: source, sortOrder: 20),
            ReplaceRule(id: "disabled", name: "停用", pattern: "A", replacement: "X", enabled: false, sortOrder: 0),
            ReplaceRule(id: "other", name: "其他源", pattern: "A", replacement: "Y", scope: "https://b.invalid", sortOrder: 1),
            ReplaceRule(id: "first", name: "先执行", pattern: "A", replacement: "B", scope: source, sortOrder: 10)
        ]
        let applicable = ReplaceRuleStore.rules(for: source, from: rules)
        #expect(applicable.map(\.id) == ["first", "second"])
        #expect(ReplaceRuleEngine.apply(applicable, to: "A") == "C")
        #expect(ReplaceRuleStore.rules(for: "", from: rules).isEmpty)
    }

    @Test("没有确认界面的文件导入不得丢弃限制后保存规则")
    @MainActor func directMixedImportDoesNotWrite() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("replace-import-\(UUID()).json")
        defer {
            if FileManager.default.fileExists(atPath: file.path) {
                do { try FileManager.default.removeItem(at: file) }
                catch { Issue.record("无法清理合成规则文件") }
            }
        }
        let store = ReplaceRuleStore(file: file)
        await #expect(throws: ReplaceRuleImportError.self) {
            _ = try await store.importFromLegadoData(MixedReplaceRuleFixture.data)
        }
        try await store.persistPendingChanges()
        #expect(store.rules.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    @Test("a replacement as long as its match still applies")
    func sameLengthReplacement() {
        let text = Self.attributed("永夜降臨。")
        #expect(ReplaceRuleEngine.apply([Self.rule("永夜", "長夜", regex: false)], to: text, from: 0))
        #expect(text.string == "長夜降臨。")
    }

    @Test("$n expands to the capture, as on the string path")
    func captureGroups() {
        let text = Self.attributed("第12章")
        let rules = [Self.rule("第(\\d+)章", "Chapter $1")]
        ReplaceRuleEngine.apply(rules, to: text, from: 0)
        #expect(text.string == "Chapter 12")
        #expect(text.string == ReplaceRuleEngine.apply(rules, to: "第12章"))
    }

    @Test("^ anchors at every line, as on the string path")
    func anchorsMatchLines() {
        let source = "甲\n  乙\n　丙"
        let rules = [Self.rule("^[\\u3000 ]+", "")]
        let text = Self.attributed(source)
        ReplaceRuleEngine.apply(rules, to: text, from: 0)
        #expect(text.string == "甲\n乙\n丙")
        #expect(text.string == ReplaceRuleEngine.apply(rules, to: source))
    }

    @Test("text before the start offset is never touched, and styling survives")
    func respectsStartAndAttributes() {
        let text = Self.attributed("永夜\n永夜")
        ReplaceRuleEngine.apply([Self.rule("永夜", "長夜長夜", regex: false)], to: text, from: 3)
        #expect(text.string == "永夜\n長夜長夜")
        let color = text.attribute(.foregroundColor, at: text.length - 1, effectiveRange: nil) as? UIColor
        #expect(color == .red)
    }

    /// `(a+)+$` on `a…ab` backtracks exponentially: 28 a's ran ~10 s on a Mac, and the
    /// display-time path held the main thread with it until the scene-update watchdog killed
    /// the app (Crashlytics 1dbb0353, 3.0.1 (146)). The rule is stopped at its timeout and the
    /// chapter keeps its text, on both entry points.
    @Test("a catastrophically backtracking rule is stopped at its timeout and changes nothing")
    func catastrophicRuleTimesOut() {
        let source = "第一段\n" + String(repeating: "a", count: 28) + "b"
        let rules = [Self.rule("(a+)+$", "X")]
        let limit = ReplaceRuleEngine.regexTimeout + 2

        let started = ProcessInfo.processInfo.systemUptime
        let text = Self.attributed(source)
        #expect(!ReplaceRuleEngine.apply(rules, to: text, from: 0))
        #expect(text.string == source)
        #expect(ProcessInfo.processInfo.systemUptime - started < limit)

        let plainStarted = ProcessInfo.processInfo.systemUptime
        #expect(ReplaceRuleEngine.apply(rules, to: source) == source)
        #expect(ProcessInfo.processInfo.systemUptime - plainStarted < limit)
    }

    @Test("a timed-out rule is skipped, the rules after it still apply")
    func rulesAfterTimeoutStillApply() {
        let source = String(repeating: "a", count: 28) + "b 永夜"
        let rules = [Self.rule("(a+)+$", "X"), Self.rule("永夜", "長夜", regex: false)]
        #expect(ReplaceRuleEngine.apply(rules, to: source) == String(repeating: "a", count: 28) + "b 長夜")
    }

    @Test("the off-main entry point gives the same text as the in-place one")
    func offMainMatchesInPlace() async {
        let rules = [Self.rule("第(\\d+)章", "Chapter $1"), Self.rule("^[\\u3000 ]+", "")]
        let source = "標題\n第12章\n　正文"
        let inPlace = Self.attributed(source)
        ReplaceRuleEngine.apply(rules, to: inPlace, from: 3)
        let offMain = Self.attributed(source)
        let edits = await ReplaceRuleEngine.ruleEditsOffMain(rules, in: source, from: 3)
        #expect(ReplaceRuleEngine.replay(edits, on: offMain))
        #expect(offMain.string == inPlace.string)
        #expect(await ReplaceRuleEngine.ruleEditsOffMain([Self.rule("永夜", "長夜")], in: source, from: 0).isEmpty)
    }

    @Test("no match reports no change")
    func noMatch() {
        let text = Self.attributed("天地漆黑")
        #expect(!ReplaceRuleEngine.apply([Self.rule("永夜", "長夜")], to: text, from: 0))
    }

    @Test("the chapter fetcher keeps the source's text; rules wait for display")
    @MainActor func fetcherDoesNotBakeRules() async {
        let rule = Self.rule("永夜", "長夜", regex: false)
        ReplaceRuleStore.shared.add(rule)
        defer { ReplaceRuleStore.shared.delete(id: rule.id) }

        let content = await ChapterFetcher.shared.resolveContent(
            parsed: ChapterParsePayload(content: "永夜，天地漆黑。", title: "第1章", sourceMatched: true, isPay: false)
        )
        #expect(content.contains("永夜"))
        #expect(!content.contains("長夜"))
    }

    /// Organizer, 2.0.7 (104): a broad rule aborted the app out of memory inside
    /// `ReplaceRuleEngine`. The display-time path then built every replacement before
    /// checking the budget, so the allocation it guards against had already happened.
    @Test("an over-budget rule stops at the match that passes the budget", arguments: [true, false])
    func overBudgetStopsEarly(regex: Bool) {
        let text = String(repeating: "a", count: 10_000) as NSString
        let rule = Self.rule(regex ? "(?=a)" : "a", String(repeating: "x", count: 100), regex: regex)
        let result = ReplaceRuleEngine.edits(of: rule, in: text, range: NSRange(location: 0, length: text.length), limit: 1_000)
        guard case .overBudget(let scanned) = result else {
            Issue.record("expected the rule to be refused, got \(String(describing: result))")
            return
        }
        // Each match adds about 100 units against a 1,000 budget: it must give up near
        // the tenth match, not after all ten thousand.
        #expect(scanned <= 11)
    }

    @Test("both entry points refuse the same over-budget rule and keep the text")
    func overBudgetKeepsText() {
        let source = String(repeating: "永夜", count: 20)
        let rules = [Self.rule("(?=.)", String(repeating: "x", count: 100))]
        #expect(ReplaceRuleEngine.replacing(rules[0], in: source, limit: 1_000) == nil)
        let text = Self.attributed(source)
        // The attributed entry's budget is fixed at 8M units, so use a rule that passes it.
        let huge = [Self.rule("(?=.)", String(repeating: "x", count: 300_000))]
        #expect(!ReplaceRuleEngine.apply(huge, to: text, from: 0))
        #expect(text.string == source)
        #expect(ReplaceRuleEngine.apply(huge, to: source) == source)
    }

    @Test("a literal rule obeys the same budget as a regex one")
    func literalBudget() {
        let rule = Self.rule("a", "xyz", regex: false)
        #expect(ReplaceRuleEngine.replacing(rule, in: "aaaa", limit: 12) == "xyzxyzxyzxyz")
        #expect(ReplaceRuleEngine.replacing(rule, in: "aaaa", limit: 11) == nil)
    }
}

// 自建规则包，不含真实书名、源地址或脚本。
enum MixedReplaceRuleFixture {
    static let data = Data("""
        [
          {"id":42,"name":"正文","pattern":"噪声","isRegex":false},
          {"id":43,"name":"标题","pattern":"标题","scopeTitle":true,"scopeContent":false},
          {"id":44,"name":"排除一本书","pattern":"保留","excludeScope":"保留本"},
          {"id":45,"name":"非法开关","pattern":"其他","scopeContent":"sometimes"}
        ]
        """.utf8)
}

