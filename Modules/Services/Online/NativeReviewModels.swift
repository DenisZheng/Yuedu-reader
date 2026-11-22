import Foundation
import CryptoKit
import CoreFoundation

/// 段评是源的只读结果；摘要键与正文段落身份分开，不保存第二份章节正文。
struct NativeReviewSummary: Equatable, Sendable {
    struct Paragraph: Identifiable, Equatable, Hashable, Sendable {
        let index: Int
        let data: String
        let count: Int
        var id: Int { index }
    }
    let paragraphs: [Paragraph]
    var runtimeVariables: [String: String] = [:]
}

struct NativeReviewItem: Identifiable, Equatable, Sendable {
    let sourceID: String?
    let name: String
    let avatar: String?
    let badges: [String]
    let text: String
    let replyToName: String?
    let image: String?
    let audio: String?
    let time: String?
    let likeCount: Int?
    let replyCount: Int?
    var replies: [NativeReviewItem]
    let id: String
}

struct NativeReviewPage: Equatable, Sendable {
    let items: [NativeReviewItem]
    let nextPageURL: String?
    var hasSeparateReplies = false
    var runtimeVariables: [String: String] = [:]
}

enum NativeReviewFailure: LocalizedError, Equatable {
    case unavailable, configuration, rule, response, budget, loop
    var errorDescription: String? {
        switch self {
        case .unavailable: localized("此來源未提供原生段評。")
        case .configuration: localized("段評規則不完整。")
        case .rule: localized("段評規則執行失敗。")
        case .response: localized("段評回應格式不正確。")
        case .budget: localized("段評超過本次讀取上限。")
        case .loop: localized("段評下一頁重複，已停止讀取。")
        }
    }
}

enum NativeReviewValues {
    static let maximumBytes = 1024 * 1024
    static let maximumItems = 1000
    static let maximumDepth = 8
    static func integer(_ value: Any?) -> Int? {
        guard let value else { return nil }
        if let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() { return nil }
        let raw = String(describing: value).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let number = Double(raw), number.isFinite, number >= -1, number <= 100_000_000 else { return nil }
        return Int(number)
    }
    static func string(_ value: Any?) -> String? {
        guard let value, !(value is NSNull) else { return nil }
        if let value = value as? String { return value.trimmingCharacters(in: .whitespacesAndNewlines) }
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }
    static func badges(_ value: Any?) -> [String] {
        let raw: [String]
        if let list = value as? [Any] { raw = list.compactMap(string) }
        else if let text = string(value), text.hasPrefix("["), let data = text.data(using: .utf8) {
            // 协议允许普通文字徽章（如[作者]）；只有有效JSON数组才解释成徽章列表。
            do { raw = try JSONDecoder().decode([String].self, from: data) }
            catch { raw = [text] }
        }
        else { raw = string(value).map { [$0] } ?? [] }
        var result: [String] = [], seen = Set<String>()
        for text in raw {
            let pieces: [String]
            if text.hasPrefix("data:") { pieces = [text] }
            else {
                let splitComma = text.contains(",") && (!text.contains("://") || text.contains(",http://") || text.contains(",https://"))
                let separator = text.contains("\n") ? "\n" : text.contains("|") ? "|" : splitComma ? "," : nil
                pieces = separator.map { text.components(separatedBy: $0) } ?? [text]
            }
            for item in pieces.map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) }) where !item.isEmpty && seen.insert(item).inserted {
                result.append(item)
            }
        }
        return result
    }
    static func absolute(_ value: Any?, base: String) -> String? {
        guard let text = string(value), !text.isEmpty else { return nil }
        return AnalyzeUrl.javaAbsoluteURL(text, base: base) ?? text
    }
    static func items(_ objects: [[String: Any]], base: String) throws -> [NativeReviewItem] {
        var remaining = maximumItems
        return try SourcePerfTrace.span("review.items.normalize", "items=\(objects.count) main=\(Thread.isMainThread)") {
            try objects.compactMap { try parseItem($0, base: base, depth: 0, remaining: &remaining) }
        }
    }
    static func item(_ object: [String: Any], base: String) throws -> NativeReviewItem? {
        var remaining = maximumItems
        return try parseItem(object, base: base, depth: 0, remaining: &remaining)
    }
    private static func parseItem(_ object: [String: Any], base: String, depth: Int, remaining: inout Int) throws -> NativeReviewItem? {
        guard depth <= maximumDepth, remaining > 0 else { throw NativeReviewFailure.budget }
        remaining -= 1
        let raw = object["content"]
        let protocolObject: [String: Any]?
        let rawText: String
        if let dictionary = raw as? [String: Any] {
            let data = try JSONSerialization.data(withJSONObject: dictionary, options: [.sortedKeys])
            rawText = String(decoding: data, as: UTF8.self)
            protocolObject = isProtocol(dictionary) ? dictionary : nil
        } else {
            rawText = string(raw) ?? ""
            // 普通评论可合法包含花括号；不是有效协议JSON时仍按原文展示，不伪造API请求成功。
            if rawText.hasPrefix("{"), let data = rawText.data(using: .utf8) {
                do {
                    let dictionary = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                    protocolObject = dictionary.flatMap { isProtocol($0) ? $0 : nil }
                } catch { protocolObject = nil }
            } else { protocolObject = nil }
        }
        let text = protocolObject == nil ? rawText : string(protocolObject?["text"]) ?? ""
        let image = absolute(protocolObject?["img"], base: base), audio = absolute(protocolObject?["audio"], base: base)
        let name = string(object["name"]) ?? ""
        guard !text.isEmpty || !name.isEmpty || image != nil || audio != nil else { return nil }
        let nested = object["replies"] as? [[String: Any]] ?? []
        guard nested.count <= maximumItems else { throw NativeReviewFailure.budget }
        let badgeValues = badges(object["badge"])
        guard text.utf8.count <= 65_536, name.utf8.count <= 4096, badgeValues.count <= 32 else { throw NativeReviewFailure.budget }
        let identifier = string(object["id"]).flatMap { $0.isEmpty ? nil : $0 }
        let identity = identifier ?? SHA256.hash(data: Data([name, text, string(protocolObject?["time"]) ?? "", image ?? "", audio ?? ""].joined(separator: "\u{0}").utf8)).map { String(format: "%02x", $0) }.joined()
        return NativeReviewItem(sourceID: identifier, name: name, avatar: absolute(object["avatar"], base: base),
            badges: badgeValues, text: ReaderHTMLUtilities.displayText(fromHTMLFragment: text),
            replyToName: string(protocolObject?["replyToName"]), image: image, audio: audio,
            time: string(protocolObject?["time"]), likeCount: integer(protocolObject?["likeCount"]),
            replyCount: integer(protocolObject?["replyCount"]),
            replies: try nested.compactMap { try parseItem($0, base: base, depth: depth + 1, remaining: &remaining) }, id: identity)
    }
    static func flattenedReplies(_ items: [NativeReviewItem]) -> [NativeReviewItem] {
        var result: [NativeReviewItem] = [], stack = Array(items.reversed()), seen = Set<String>()
        while var item = stack.popLast() {
            stack.append(contentsOf: item.replies.reversed())
            item.replies = []
            if seen.insert(item.id).inserted { result.append(item) }
        }
        return result
    }

    private static func isProtocol(_ object: [String: Any]) -> Bool {
        object.keys.contains { ["text", "replyToName", "img", "audio", "time", "likeCount", "replyCount"].contains($0) }
    }
}
