import Foundation
import SwiftSoup

/// 仅把需要原生认证/解码的图片地址换成有登记的能力URL；不净化规则网页的脚本、iframe或交互HTML。
enum RSSImageMarkup {
    struct Document: Sendable { var html: String; var images: [String: URL] }
    nonisolated static func rewrite(_ html: String, base: URL?, prefix: String) throws -> Document {
        dispatchPrecondition(condition: .notOnQueue(.main))
        return try SourcePerfTrace.span("rss.image.markup", "main=\(Thread.isMainThread),bytes=\(html.utf8.count)") {
            guard html.utf8.count <= 8 * 1_024 * 1_024 else { throw RSSWebFailure.resourceUnavailable }
            let document = try SwiftSoup.parse(html)
            document.outputSettings().prettyPrint(pretty: false)
            var images: [String: URL] = [:]
            func register(_ raw: String) throws -> String {
                guard let url = URL(string: raw, relativeTo: base)?.absoluteURL, SourceRequestHeaderScope.origin(url) != nil else { return raw }
                guard images.count < 2_048, url.absoluteString.utf8.count <= 8_192 else { throw RSSWebFailure.resourceUnavailable }
                let id = UUID().uuidString.lowercased()
                images[id] = url
                return prefix + id
            }
            for element in try document.select("img,picture source") {
                if element.tagName() == "img", let raw = try element.hasAttr("src") ? element.attr("src") : nil, !raw.isEmpty {
                    try element.attr("data-reader-original-src", URL(string: raw, relativeTo: base)?.absoluteURL.absoluteString ?? raw)
                    try element.attr("src", register(raw))
                }
                if element.hasAttr("srcset") {
                    let raw = try element.attr("srcset")
                    try element.attr("data-reader-original-srcset", raw)
                    try element.attr("srcset", srcset(raw, transform: register))
                }
            }
            return Document(html: try document.outerHtml(), images: images)
        }
    }
    /// WHATWG srcset的URL/描述符边界：URL内逗号不等于分隔符，URL尾逗号或描述符后的逗号才分隔。
    nonisolated static func srcset(_ raw: String, transform: (String) throws -> String) throws -> String {
        guard raw.utf8.count <= 16_384 else { throw RSSWebFailure.resourceUnavailable }
        let chars = Array(raw)
        var index = 0, result: [String] = []
        func space(_ c: Character) -> Bool { c == " " || c == "\t" || c == "\n" || c == "\r" || c == "\u{000c}" }
        while index < chars.count {
            while index < chars.count && (space(chars[index]) || chars[index] == ",") { index += 1 }
            let start = index
            while index < chars.count && !space(chars[index]) { index += 1 }
            var url = String(chars[start..<index])
            guard !url.isEmpty else { break }
            var descriptor = ""
            if url.last == "," { while url.last == "," { url.removeLast() } }
            else {
                let begin = index
                var depth = 0
                while index < chars.count {
                    if chars[index] == ",", depth == 0 { break }
                    if chars[index] == "(" { depth += 1 }
                    if chars[index] == ")" { depth = max(0, depth - 1) }
                    index += 1
                }
                descriptor = String(chars[begin..<index]).trimmingCharacters(in: .whitespacesAndNewlines)
                if index < chars.count { index += 1 }
            }
            guard result.count < 64 else { throw RSSWebFailure.resourceUnavailable }
            result.append(try transform(url) + (descriptor.isEmpty ? "" : " " + descriptor))
        }
        return result.joined(separator: ", ")
    }
}
