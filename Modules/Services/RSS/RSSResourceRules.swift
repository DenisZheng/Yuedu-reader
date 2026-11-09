import Foundation
import WebKit

/// Android合同：黑名单优先；前缀或全串正则匹配；主文档/原生注入不经过子资源过滤。
/// WebKit不能表达的Java正则显式拒绝，原生资源匹配另有ICU进度预算，不能卡住JS执行器。
struct RSSResourceRules: Sendable {
    struct Blocked: Error { }
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
        let black = (source.contentBlacklist ?? "").split(separator: ",").map(String.init).filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let white = (source.contentWhitelist ?? "").split(separator: ",").map(String.init).filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let values = black.isEmpty ? white : black
        guard values.count <= 64, values.reduce(0, { $0 + $1.utf8.count }) <= 32_768 else { throw RSSWebFailure.resourceRuleUnsupported }
        blacklist = !black.isEmpty
        entries = []
        var rules: [[String: Any]] = []
        func rule(_ pattern: String, _ action: String) -> [String: Any] {
            ["trigger": ["url-filter": pattern, "url-filter-is-case-sensitive": true], "action": ["type": action]]
        }
        if black.isEmpty && !white.isEmpty { rules.append(rule(".*", "block")) }
        for value in values {
            let regex: NSRegularExpression?
            do { regex = try NSRegularExpression(pattern: "^(?:" + value + ")$") }
            catch { regex = nil } // Android正则无效时仍保留合法的字面量前缀分支。
            entries.append(.init(prefix: value, regex: regex))
            let action = blacklist ? "block" : "ignore-previous-rules"
            rules.append(rule("^" + NSRegularExpression.escapedPattern(for: value), action))
            if regex != nil { rules.append(rule("^(" + value + ")$", action)) }
        }
        if !rules.isEmpty { rules.append(rule("^reader-rss-image://", "ignore-previous-rules")) }
        encoded = rules.isEmpty ? nil : String(decoding: try JSONSerialization.data(withJSONObject: rules), as: UTF8.self)
        identifier = "rss-resource-" + RSSIdentity.digest(["v1", source.id, source.contentBlacklist ?? "", source.contentWhitelist ?? ""])
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
