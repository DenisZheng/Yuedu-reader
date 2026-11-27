import Foundation
import WebKit

/// Android合同：黑名单优先；前缀或全串正则匹配；主文档/原生注入不经过子资源过滤。
/// WebKit不能表达的Java正则显式拒绝，原生资源匹配另有ICU进度预算，不能卡住JS执行器。
struct RSSResourceRules: Sendable {
    struct Blocked: Error { }
    private static let maxEntries = 64
    private struct Entry: Sendable {
        var prefix: String
        var regex: NSRegularExpression?
    }
    private var entries: [Entry]
    private var blacklist: Bool
    let encoded: String?
    let identifier: String

    init(source: RSSSource) throws {
        dispatchPrecondition(condition: .notOnQueue(.main))
        func splitRules(_ raw: String?) -> [String] {
            (raw ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        }
        let black = splitRules(source.contentBlacklist)
        let values = black.isEmpty ? splitRules(source.contentWhitelist) : black
        guard values.count <= Self.maxEntries, values.reduce(0, { $0 + $1.utf8.count }) <= 32_768 else {
            throw RSSWebFailure.resourceRuleUnsupported
        }
        blacklist = !black.isEmpty
        let maxWebRules = Self.maxEntries * 2 + (blacklist ? 0 : 1)
        entries = []
        var rules: [[String: Any]] = []
        func rule(_ pattern: String, _ action: String) -> [String: Any] {
            ["trigger": ["url-filter": pattern, "url-filter-is-case-sensitive": true], "action": ["type": action]]
        }
        if !blacklist && !values.isEmpty { rules.append(rule(".*", "block")) }
        let action = blacklist ? "block" : "ignore-previous-rules"
        for value in values {
            let regex: NSRegularExpression?
            do { regex = try NSRegularExpression(pattern: "^(?:" + value + ")$") }
            catch { regex = nil } // Android正则无效时仍保留合法的字面量前缀分支。
            let patterns = regex == nil ? [] : try Self.webPatterns(for: value)
            // 展开后仍按原有编译条数上限；不能只安装其中一部分。
            guard rules.count + 1 + patterns.count <= maxWebRules else { throw RSSWebFailure.resourceRuleUnsupported }
            entries.append(.init(prefix: value, regex: regex))
            rules.append(rule("^" + NSRegularExpression.escapedPattern(for: value), action))
            rules.append(contentsOf: patterns.map { rule($0, action) })
        }
        if !rules.isEmpty { rules.append(rule("^reader-rss-image://", "ignore-previous-rules")) }
        encoded = rules.isEmpty ? nil : String(decoding: try JSONSerialization.data(withJSONObject: rules), as: UTF8.self)
        identifier = "rss-resource-" + RSSIdentity.digest(["v2", source.id, source.contentBlacklist ?? "", source.contentWhitelist ?? ""])
    }

    private static func webPatterns(for value: String) throws -> [String] {
        let whole = ["^(\(value))$"]
        let prefix = ".*(?:", suffix = ").*"
        guard value.hasPrefix(prefix), value.hasSuffix(suffix) else { return whole }
        let body = value.dropFirst(prefix.count).dropLast(suffix.count)
        let branches = body.split(separator: "|", maxSplits: maxEntries, omittingEmptySubsequences: false)
        guard branches.count <= maxEntries else { throw RSSWebFailure.resourceRuleUnsupported }
        // WebKit 不支持 |。只展开可等价拆分的平坦分支；复杂语法仍由编译器严格检查。
        let unsupported = Set(#"()[]{}^$\"#.utf8)
        guard branches.count > 1, branches.allSatisfy({ branch in
            !branch.isEmpty && branch.replacingOccurrences(of: #"\."#, with: "").utf8.allSatisfy {
                $0 < 128 && !unsupported.contains($0)
            }
        }) else { return whole }
        return branches.map { "^.*\($0).*$" }
    }

    func allows(_ url: URL) throws -> Bool {
        guard !entries.isEmpty else { return true }
        let value = url.absoluteString
        guard value.utf8.count <= 32_768 else { throw RSSWebFailure.resourceRuleUnsupported }
        let deadline = DispatchTime.now().uptimeNanoseconds + 20_000_000
        for entry in entries {
            if value.hasPrefix(entry.prefix) { return !blacklist }
            guard let regex = entry.regex else { continue }
            var matched = false, exceeded = false
            regex.enumerateMatches(in: value, options: [.reportProgress, .reportCompletion], range: NSRange(value.startIndex..., in: value)) { result, _, stop in
                if DispatchTime.now().uptimeNanoseconds > deadline { exceeded = true; stop.pointee = true }
                if result != nil { matched = true; stop.pointee = true }
            }
            if exceeded { throw RSSWebFailure.resourceRuleUnsupported }
            if matched { return !blacklist }
        }
        return blacklist
    }
    @MainActor func compiled() async throws -> WKContentRuleList? {
        guard let encoded else { return nil }
        do {
            let existing: WKContentRuleList? = try await withCheckedThrowingContinuation { continuation in
                WKContentRuleListStore.default().lookUpContentRuleList(forIdentifier: identifier) { value, error in
                    if let error, (error as NSError).domain != WKError.errorDomain || (error as NSError).code != WKError.Code.contentRuleListStoreLookUpFailed.rawValue { continuation.resume(throwing: error) }
                    else { continuation.resume(returning: value) }
                }
            }
            if let existing { return existing }
            guard let compiled = try await WKContentRuleListStore.default().compileContentRuleList(forIdentifier: identifier, encodedContentRuleList: encoded) else { throw RSSWebFailure.resourceRuleUnsupported }
            return compiled
        } catch { throw RSSWebFailure.resourceRuleUnsupported }
    }
}
