import Foundation
import Combine
import CoreFoundation
import os

/// Singleton store for user-configurable replace rules.
///
/// Rules are persisted to `Library/replace_rules.json`.  On first launch a set
/// of useful preset rules is installed.  The store is observable so SwiftUI
/// views update automatically when rules change.
///
/// Main-actor owned; the content builders read the enabled rules off main through
/// `rules(for:)`, a lock-guarded snapshot that every change to `rules` refreshes.
@MainActor
final class ReplaceRuleStore: @MainActor ObservableObject {

    static let shared = ReplaceRuleStore()

    @Published private(set) var rules: [ReplaceRule] {
        didSet {
            let rules = self.rules
            if storageURL == Self.fileURL { Self.snapshot.withLock { $0 = rules } }
            revision &+= 1
        }
    }

    /// Bumped by every change to `rules`, so whatever holds text the rules produced
    /// (全書搜尋's results) can tell that it is stale. Not persisted.
    private(set) var revision = 0

    private nonisolated static let fileURL = FileManager.default
        .urls(for: .libraryDirectory, in: .userDomainMask).first!
        .appendingPathComponent("replace_rules.json")

    /// The rules as last written, for readers off main. Loaded from disk on first use —
    /// whichever comes first, a content builder or the store — so neither waits for the other.
    private nonisolated static let snapshot = OSAllocatedUnfairLock(initialState: initialRules())

    /// Marks that the built-in presets have been installed on this install. Without it,
    /// deleting every rule made the next launch treat the store as brand new and put the
    /// presets back, so the rules could not be removed. Cleared with the app, so a real
    /// reinstall still seeds them.
    private nonisolated static let presetsInstalledKey = "yd_replace_presets_installed"

    private let storageURL: URL
    private init() {
        storageURL = Self.fileURL
        rules = Self.snapshot.withLock { $0 }
    }

    /// 隔离验收使用指定文件，不读写生产单例及其后台快照。
    init(file: URL, rules: [ReplaceRule] = []) {
        storageURL = file
        self.rules = rules
    }

    private nonisolated static func initialRules() -> [ReplaceRule] {
        var initial = readRules(at: fileURL) ?? []
        if initial.isEmpty, !UserDefaults.standard.bool(forKey: presetsInstalledKey) {
            initial = presetRules()
            UserDefaults.standard.set(true, forKey: presetsInstalledKey)
            write(initial, to: fileURL)
        }
        return initial
    }

    // MARK: - CRUD

    func add(_ rule: ReplaceRule) {
        rules.append(rule)
        save()
    }

    func update(_ rule: ReplaceRule) {
        guard let idx = rules.firstIndex(where: { $0.id == rule.id }) else { return }
        rules[idx] = rule
        save()
    }

    func delete(id: String) {
        rules.removeAll { $0.id == id }
        save()
    }

    func delete(ids: Set<String>) {
        guard !ids.isEmpty else { return }
        rules.removeAll { ids.contains($0.id) }
        save()
    }

    func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        var copy = rules
        let indices = source.sorted().reversed()
        var removed: [ReplaceRule] = []
        for i in indices {
            removed.insert(copy.remove(at: i), at: 0)
        }
        let adjustedDest = destination - source.filter { $0 < destination }.count
        copy.insert(contentsOf: removed, at: adjustedDest)
        rules = copy
        for (i, _) in rules.enumerated() { rules[i].sortOrder = i }
        save()
    }

    // MARK: - Query

    /// Rules that apply to the given book-source URL, sorted by `sortOrder`. Safe from any
    /// thread: reads the snapshot, not the main-actor `rules`.
    nonisolated static func rules(for sourceUrl: String) -> [ReplaceRule] {
        rules(for: sourceUrl, from: snapshot.withLock { $0 })
    }

    /// 生产快照和隔离测试共用启用过滤、范围选择与执行顺序，不修改共享快照。
    nonisolated static func rules(for sourceUrl: String, from rules: [ReplaceRule]) -> [ReplaceRule] {
        rules.filter { $0.enabled && Self.scope($0.scope, matches: sourceUrl) }
            .sorted { $0.sortOrder < $1.sortOrder }
    }

    nonisolated static func scope(_ scope: String, matches sourceUrl: String) -> Bool {
        let trimmed = scope.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "global", trimmed != "*" else { return true }
        guard !sourceUrl.isEmpty, trimmed.contains(sourceUrl) else { return false }
        // 不能解释的旧范围只保留整体精确匹配；列表不能作为一个源地址命中。
        return sourceAddresses(in: trimmed)?.contains(sourceUrl) ?? (trimmed == sourceUrl)
    }

    private nonisolated static let scopeSeparators = CharacterSet(charactersIn: ",，;；").union(.newlines)

    fileprivate nonisolated static func supportsScope(_ scope: String) -> Bool {
        scope == "global" || scope == "*" || sourceAddresses(in: scope) != nil
    }

    /// 只在分隔处后面确实有 HTTP(S) 地址时切分。保留前一个地址能容纳的标点；
    /// 连续标点不能留在主机或端口时，按旧列表的空分隔处理。
    private nonisolated static func sourceAddresses(in scope: String) -> [String]? {
        var start = scope.startIndex
        var cursor = start
        var addresses: [String] = []
        func isSeparator(_ character: Character) -> Bool {
            character.unicodeScalars.allSatisfy(scopeSeparators.contains)
        }
        func appendAddress(upTo end: String.Index) -> Bool {
            let address = scope[start..<end].trimmingCharacters(in: .whitespacesAndNewlines)
            guard isSourceAddress(address) else { return false }
            addresses.append(address)
            return true
        }
        while cursor < scope.endIndex {
            let boundary = cursor
            scope.formIndex(after: &cursor)
            guard isSeparator(scope[boundary]) else { continue }
            var preferredBoundary = boundary
            var sawWhitespace = scope[boundary].isWhitespace
            var reachedPunctuationAfterWhitespace = false
            while cursor < scope.endIndex {
                let character = scope[cursor]
                if character.isWhitespace {
                    sawWhitespace = true
                } else if !isSeparator(character) {
                    break
                } else if !reachedPunctuationAfterWhitespace {
                    // 尽量保留前面的标点，但不能留下地址内部的空白。
                    preferredBoundary = cursor
                    reachedPunctuationAfterWhitespace = sawWhitespace
                }
                scope.formIndex(after: &cursor)
            }
            let prefix = scope[cursor...].prefix(8).lowercased()
            let schemeLength: Int
            if prefix.hasPrefix("http://") { schemeLength = 7 }
            else if prefix == "https://" { schemeLength = 8 }
            else { continue }
            // 查询值中的 "http://" 不是下一个地址；先确认确实有有效的 authority。
            let hostStart = scope.index(cursor, offsetBy: schemeLength)
            var hostEnd = hostStart
            while hostEnd < scope.endIndex, !isSeparator(scope[hostEnd]), !scope[hostEnd].isWhitespace,
                  !"/?#".contains(scope[hostEnd]) {
                scope.formIndex(after: &hostEnd)
            }
            guard isSourceAddress(String(scope[cursor..<hostEnd])) else { continue }
            guard appendAddress(upTo: preferredBoundary) ||
                    (preferredBoundary != boundary && appendAddress(upTo: boundary)) else { return nil }
            start = cursor
        }
        return appendAddress(upTo: scope.endIndex) ? addresses : nil
    }

    private nonisolated static func isSourceAddress(_ address: String) -> Bool {
        guard address.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
              let url = URLComponents(string: address), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https", let host = url.host, !host.isEmpty else { return false }
        return host.rangeOfCharacter(from: scopeSeparators) == nil
    }

    func replaceRulesFromSync(_ syncedRules: [ReplaceRule]) {
        // Deduplicate here too: until every device has run the stable-id build, a merge
        // can still hand back the old duplicated set from the cloud.
        rules = Self.deduplicated(syncedRules.sorted { $0.sortOrder < $1.sortOrder })
        save()
    }

    @discardableResult
    func importFromLegadoJSON(_ json: String) async throws -> Int {
        try await importFromLegadoData(Data(json.utf8))
    }

    /// 共享文件等没有确认界面的入口只接收完整支持的规则包。
    @discardableResult
    func importFromLegadoData(_ data: Data) async throws -> Int {
        let review = try await ReplaceRuleImportParser.review(data: data)
        guard !review.hasIssues else { throw ReplaceRuleImportError.incompletePack }
        return try await importConfirmedRules(review)
    }

    /// 手动预览确认后仅提交可支持的规则，合并时仍保留现有规则身份。
    func importConfirmedRules(_ review: ReplaceRuleImportReview) async throws -> Int {
        guard !review.rules.isEmpty else { throw ReplaceRuleImportError.noRules }
        let before = revision
        let merged = await Self.changedImport(review.rules, into: rules)
        try Task.checkCancellation()
        guard revision == before else { throw ReplaceRuleImportError.rulesChanged }
        if let merged { rules = merged; save() }
        try await persistPendingChanges()
        return review.rules.count
    }

    @concurrent private nonisolated static func changedImport(
        _ incoming: [ReplaceRule], into existing: [ReplaceRule]
    ) async -> [ReplaceRule]? {
        SourcePerfTrace.span("replace.import.merge", "main=\(Thread.isMainThread) incoming=\(incoming.count) existing=\(existing.count)") {
            let merged = merging(incoming, into: existing)
            return merged == existing ? nil : merged
        }
    }

    /// 导入和规则订阅共用身份合并；Android数字ID映射后保持稳定，更新不插入第二条规则。
    nonisolated static func merging(_ imported: [ReplaceRule], into existing: [ReplaceRule]) -> [ReplaceRule] {
        var result = existing
        var nextOrder = (existing.map(\.sortOrder).max() ?? -1) + 1
        for var rule in imported {
            let index = result.firstIndex { $0.id == rule.id }
                ?? result.firstIndex { $0.pattern == rule.pattern && $0.replacement == rule.replacement && $0.scope == rule.scope }
            if let index {
                rule.id = result[index].id; rule.sortOrder = result[index].sortOrder; result[index] = rule
            } else {
                rule.sortOrder = nextOrder; nextOrder += 1; result.append(rule)
            }
        }
        return result
    }

    func commitSubscriptionRules(_ next: [ReplaceRule], expectedRevision: Int, changed: Bool) async throws {
        try Task.checkCancellation()
        guard revision == expectedRevision else { throw ReplaceRuleImportError.invalidData }
        if changed { rules = next; save() }
        try await persistPendingChanges()
    }

    func persistPendingChanges() async throws {
        await withCheckedContinuation { continuation in Self.persistQueue.async { continuation.resume() } }
        if Self.persistenceFailed.withLock({ $0[storageURL] == true }) {
            save()
            await withCheckedContinuation { continuation in Self.persistQueue.async { continuation.resume() } }
        }
        if Self.persistenceFailed.withLock({ $0[storageURL] == true }) { throw CocoaError(.fileWriteUnknown) }
    }

    /// Re-reads the on-disk store into memory. Used after an iCloud restore
    /// overwrites `replace_rules.json` so the live UI reflects it without a relaunch.
    func reloadFromDisk() {
        load()
    }

    /// 已验证的WebDAV快照在后台去重；这里不重复读取或重写规则文件。
    @discardableResult
    func applyRestoredRules(_ prepared: [ReplaceRule], expectedRevision: Int? = nil) -> Bool {
        guard expectedRevision == nil || expectedRevision == revision else { return false }
        rules = prepared
        return true
    }

    // MARK: - Persistence

    private func load() {
        guard let loaded = Self.readRules(at: storageURL) else { return }
        rules = loaded
    }

    /// The deduplicated rules on disk; nil when there is no readable file. Persists
    /// immediately when copies were dropped, so the next sync sees the shrunken set and
    /// tombstones the ids that went away.
    private nonisolated static func readRules(at fileURL: URL) -> [ReplaceRule]? {
        guard FileManager.default.fileExists(atPath: fileURL.path),
              let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([ReplaceRule].self, from: data) else {
            return nil
        }
        let rules = deduplicated(decoded)
        if rules.count != decoded.count { write(rules, to: fileURL) }
        return rules
    }

    private nonisolated static let persistQueue = DispatchQueue(label: "readerfork.replace.persist", qos: .utility)
    private nonisolated static let pendingWrite = OSAllocatedUnfairLock(initialState: [URL: [ReplaceRule]]())
    private nonisolated static let persistenceFailed = OSAllocatedUnfairLock(initialState: [URL: Bool]())

    private func save() {
        let snapshot = rules
        let file = storageURL
        let enqueue = Self.pendingWrite.withLock { value in
            let enqueue = value[file] == nil
            value[file] = snapshot
            return enqueue
        }
        guard enqueue else { return }
        Self.persistQueue.async {
            guard let snapshot = Self.pendingWrite.withLock({ $0.removeValue(forKey: file) }) else { return }
            Self.write(snapshot, to: file)
        }
    }

    @discardableResult private nonisolated static func write(_ rules: [ReplaceRule], to fileURL: URL) -> Bool {
        do {
            try SourcePerfTrace.span("replace.persist", "main=\(Thread.isMainThread) rules=\(rules.count)") {
                try JSONEncoder().encode(rules).write(to: fileURL, options: .atomic)
            }
            persistenceFailed.withLock { $0[fileURL] = nil }
            return true
        } catch {
            persistenceFailed.withLock { $0[fileURL] = true }
            AppLogger.cache("替换规则写入失败", context: ["code": String((error as NSError).code)])
            return false
        }
    }

    // MARK: - Presets

    /// Preset ids are fixed strings, never fresh UUIDs.
    ///
    /// iCloud merges rules by id. When every install minted new UUIDs for the same five
    /// presets, a reinstall (or a second device) produced five ids the cloud had never
    /// seen, so the merge kept both sets and the list grew by five every time. A stable
    /// id makes those the same record everywhere, and the merge collapses them.
    private nonisolated static func presetRules() -> [ReplaceRule] {
        let presets: [(id: String, name: String, pattern: String, replacement: String)] = [
            ("preset.ad-filter.leading", "廣告文字過濾（首行）", "^\\s*本章節.*?(?=\\n)", ""),
            ("preset.ad-filter.trailing", "廣告文字過濾（尾行）", "(?<=\\n).*?閱讀\\s*$", ""),
            ("preset.collapse-blank-lines", "合并多餘空行", "\\n{3,}", "\n\n"),
            ("preset.trim-leading-space", "清除全形空格開頭", "^[\\u3000\\s]+", ""),
            ("preset.trim-trailing-space", "清除行末空白", "[\\t ]+$", ""),
        ]
        return presets.enumerated().map { i, preset in
            ReplaceRule(
                id: preset.id,
                name: preset.name,
                pattern: preset.pattern,
                replacement: preset.replacement,
                isRegex: true,
                sortOrder: i
            )
        }
    }

    /// Collapses rules that would do exactly the same substitution.
    ///
    /// Cleans up what the UUID-per-install bug above already duplicated on people's
    /// devices: running the identical pattern twice can never change the output, so the
    /// copies are pure noise. Keeping the lowest id makes two devices independently pick
    /// the same survivor, and the ids that disappear are tombstoned by the normal sync
    /// path so the copies do not come back from the cloud.
    ///
    /// Can be deleted once no install carries duplicates from before the stable-id fix.
    /// Not `private` so `ReplaceRuleDeduplicationTests` can cover it without reaching
    /// through the singleton's private init.
    nonisolated static func deduplicated(_ input: [ReplaceRule]) -> [ReplaceRule] {
        var survivorIndexByKey: [String: Int] = [:]
        var output: [ReplaceRule] = []
        for rule in input {
            let key = "\(rule.pattern)\u{1F}\(rule.replacement)\u{1F}\(rule.scope)\u{1F}\(rule.isRegex)"
            guard let existing = survivorIndexByKey[key] else {
                survivorIndexByKey[key] = output.count
                output.append(rule)
                continue
            }
            if rule.id < output[existing].id {
                output[existing] = rule
            }
        }
        return output
    }
}

enum ReplaceRuleImportError: LocalizedError {
    case invalidData, parseError, ambiguousPack, noRules, incompletePack, tooLarge, rulesChanged

    var errorDescription: String? {
        switch self {
        case .invalidData: localized("無法讀取文件")
        case .parseError: localized("替換規則 JSON 解析失敗")
        case .ambiguousPack: localized("檔案包含多組替換規則，請只保留一組。")
        case .noRules: localized("未找到可匯入的替換規則")
        case .incompletePack: localized("檔案含不支援或無效的規則，請到替換規則頁面檢查後再匯入。")
        case .tooLarge: localized("替換規則檔案超過匯入上限")
        case .rulesChanged: localized("本機替換規則已變更，請再試一次。")
        }
    }
}

struct ReplaceRuleImportReview: Sendable {
    struct Row: Identifiable, Sendable, Equatable {
        enum Outcome: Sendable, Equatable {
            case supported(ReplaceRule, originalID: String?)
            case unsupported([String])
            case invalid([String])
        }

        let id: Int // 原始文件中的行序号（从 1 开始），不是规则 ID。
        let outcome: Outcome
    }

    let rows: [Row]
    let rules: [ReplaceRule]
    var hasIssues: Bool { rows.count != rules.count }

    init(rows: [Row]) {
        self.rows = rows
        rules = rows.compactMap {
            if case let .supported(rule, _) = $0.outcome { return rule }
            return nil
        }
    }
}

enum ReplaceRuleImportParser {
    static let maximumBytes = 8 * 1_024 * 1_024
    private static let maximumRules = 10_000
    private static let patternKeys = ["pattern", "regex", "replaceRegex"]
    private static let namedPacks = ["replaceRules", "replaceRule", "replaceRuleList"]
    private static let wrapperKeys = namedPacks + ["rules", "data"]

    /// 只沿数组和规则包装查找实际规则。仅有包装名时才询问是否为书，且只询问一次。
    static func recognizesPack(_ root: Any, requiresRuleMarker: @autoclosure () -> Bool = false) -> Bool {
        var hasNamedPack = false
        func containsPattern(_ value: Any, isArrayRow: Bool = false) -> Bool {
            if let rows = value as? [Any] {
                return rows.contains { containsPattern($0, isArrayRow: true) }
            }
            guard let object = value as? [String: Any] else { return false }
            if hasPatternField(object) { return true }
            for key in wrapperKeys {
                guard let child = object[key] else { continue }
                // 章节数组中的一行可以附带空 replaceRules；仅此不能把整本书改道。
                if namedPacks.contains(key), !isArrayRow || (child as? [Any])?.isEmpty != true {
                    hasNamedPack = true
                }
                if containsPattern(child) { return true }
            }
            return false
        }
        return containsPattern(root) || (hasNamedPack && !requiresRuleMarker())
    }

    private static func hasPatternField(_ object: [String: Any]) -> Bool {
        patternKeys.contains { object[$0] != nil }
    }

    @concurrent static func review(file url: URL) async throws -> ReplaceRuleImportReview {
        try Task.checkCancellation()
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        let data: Data
        do {
            data = try SourcePerfTrace.span("replace.import.read", "main=\(Thread.isMainThread)") {
                try DocumentImportReader.read(url, maximumBytes: maximumBytes)
            }
        } catch DocumentImportReader.Failure.tooLarge {
            throw ReplaceRuleImportError.tooLarge
        } catch {
            throw ReplaceRuleImportError.invalidData
        }
        return try makeReview(data)
    }

    @concurrent static func review(data: Data) async throws -> ReplaceRuleImportReview {
        try makeReview(data)
    }

    private static func makeReview(_ data: Data) throws -> ReplaceRuleImportReview {
        try Task.checkCancellation()
        guard data.count <= maximumBytes else { throw ReplaceRuleImportError.tooLarge }
        return try SourcePerfTrace.span("replace.import.review", "main=\(Thread.isMainThread) bytes=\(data.count)") {
            let object: Any
            do { object = try JSONSerialization.jsonObject(with: data) }
            catch { throw ReplaceRuleImportError.parseError }
            let raw = try ruleObjects(from: object)
            guard raw.count <= maximumRules else { throw ReplaceRuleImportError.tooLarge }
            return try ReplaceRuleImportReview(rows: raw.enumerated().map { index, value in
                .init(id: index + 1, outcome: try reviewRow(value))
            })
        }
    }

    private static func ruleObjects(from object: Any) throws -> [Any] {
        if let array = object as? [Any] { return array }
        guard let dictionary = object as? [String: Any] else { throw ReplaceRuleImportError.invalidData }
        if let nested = try checkedWrapper(in: dictionary) { return try ruleObjects(from: nested) }
        return [dictionary] // 单条对象即使缺少必填字段，也保留错误诊断。
    }

    /// 顶层和数组行都遵守相同的歧义约束，不能靠多包一层数组绕过检查。
    private static func checkedWrapper(in dictionary: [String: Any]) throws -> Any? {
        let wrappers = wrapperKeys.compactMap { dictionary[$0] }
        guard wrappers.count <= 1, wrappers.isEmpty || !hasPatternField(dictionary) else {
            throw ReplaceRuleImportError.ambiguousPack
        }
        return wrappers.first
    }

    /// 数组行只接受单条规则。即使行形状不合法，也沿已知包装查到内层：
    /// 找到歧义就拒绝整个包，而不是把那行降为可略过的错误。
    private static func checkedRuleDictionary(from object: Any) throws -> [String: Any]? {
        try Task.checkCancellation()
        if let array = object as? [Any] {
            for child in array { _ = try checkedRuleDictionary(from: child) }
            return nil
        }
        guard let dictionary = object as? [String: Any] else { return nil }
        if let nested = try checkedWrapper(in: dictionary) {
            _ = try checkedRuleDictionary(from: nested)
            return nil
        }
        return dictionary
    }

    private static func reviewRow(_ object: Any) throws -> ReplaceRuleImportReview.Row.Outcome {
        guard let dictionary = try checkedRuleDictionary(from: object) else { return .invalid([]) }
        var invalid: [String] = []
        func read<T>(_ keys: [String], selecting: (T) -> Bool = { _ in true }, _ decode: (Any) -> T?) -> T? {
            var value: T?
            for key in keys {
                guard let raw = dictionary[key] else { continue }
                guard let decoded = decode(raw) else { invalid.append(key); continue }
                if value == nil, selecting(decoded) { value = decoded }
            }
            return value
        }
        // 旧包使用首个非空文本别名；空字符串不应盖掉后面的替换值。
        func readTextAlias(_ keys: [String]) -> String? {
            read(keys, selecting: { !$0.isEmpty }) { $0 as? String }
        }
        let pattern = readTextAlias(patternKeys)
        if pattern == nil {
            let key = patternKeys.first { dictionary[$0] != nil } ?? "pattern"
            if !invalid.contains(key) { invalid.append(key) }
        }
        let name = read(["name"]) { $0 as? String }
        let group = read(["group"], nullableString)
        let replacement = readTextAlias(["replacement", "replace"])
        let scope = read(["scope"], nullableString)
        let exclusion = read(["excludeScope"], nullableString)
        let title = read(["scopeTitle"], boolean)
        let body = read(["scopeContent"], boolean)
        let source = read(["scopeSource"], boolean)
        let regex = read(["isRegex"], boolean)
        let enabled = read(["isEnabled", "enabled"], boolean)
        let timeout = read(["timeoutMillisecond"], integer)
        let order = read(["sortOrder", "order"], integer)
        let originalID = read(["id"], identifier)
        guard invalid.isEmpty, let pattern else { return .invalid(invalid) }

        let trimmedScope = scope?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        var unsupported: [String] = []
        if title == true { unsupported.append("scopeTitle") }
        if body == false { unsupported.append("scopeContent") }
        if source == true { unsupported.append("scopeSource") }
        if let exclusion, !exclusion.isEmpty { unsupported.append("excludeScope") }
        if let scope, !scope.isEmpty, !ReplaceRuleStore.supportsScope(trimmedScope) { unsupported.append("scope") }
        if let timeout, timeout != Int(ReplaceRuleEngine.regexTimeout * 1_000) { unsupported.append("timeoutMillisecond") }
        if regex != false, replacement?.hasPrefix("@js:") == true { unsupported.append("replacement") }
        guard unsupported.isEmpty else { return .unsupported(unsupported) }

        if regex != false {
            do { _ = try ReplaceRuleEngine.compileRegex(pattern) }
            catch {
                let key = patternKeys.first { (dictionary[$0] as? String)?.isEmpty == false } ?? "pattern"
                return .invalid([key])
            }
        }

        let rawName = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let rawGroup = group?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let displayName = rawGroup.isEmpty ? rawName : (rawName.isEmpty ? rawGroup : "\(rawName) (\(rawGroup))")
        let id = originalID.map { Int64($0) == nil ? $0 : "legado:" + $0 } ?? UUID().uuidString
        return .supported(ReplaceRule(id: id, name: displayName, pattern: pattern,
            replacement: replacement ?? "", isRegex: regex ?? true, enabled: enabled ?? true,
            scope: trimmedScope.isEmpty ? "global" : trimmedScope, sortOrder: order ?? 0), originalID: originalID)
    }

    private static func nullableString(_ raw: Any) -> String? {
        raw is NSNull ? "" : raw as? String
    }

    private static func boolean(_ raw: Any) -> Bool? {
        if let text = raw as? String {
            switch text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "true", "1", "yes", "y": return true
            case "false", "0", "no", "n": return false
            default: return nil
            }
        }
        guard let number = raw as? NSNumber else { return nil }
        if number.compare(0) == .orderedSame { return false }
        if number.compare(1) == .orderedSame { return true }
        return nil
    }

    private static func integer(_ raw: Any) -> Int? {
        if let text = raw as? String { return Int(text.trimmingCharacters(in: .whitespacesAndNewlines)) }
        guard let number = raw as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        return number as? Int
    }

    private static func identifier(_ raw: Any) -> String? {
        if let text = raw as? String { return text.isEmpty ? nil : text }
        guard let number = raw as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              Int64(number.stringValue) != nil else { return nil }
        return number.stringValue
    }
}
