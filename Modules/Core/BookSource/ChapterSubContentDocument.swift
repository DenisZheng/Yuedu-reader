import Foundation

/// 只解析当前章有限副文；cue不持久化，原文仍由ChapterCacheRepository拥有。
struct ChapterSubContentDocument: Sendable {
    struct Cue: Identifiable, Equatable, Sendable {
        let id: Int
        let seconds: Double?
        let text: String
        var timeLabel: String? {
            seconds.map { String(format: "%02d:%02d", Int($0) / 60, Int($0) % 60) }
        }
    }
    let cues: [Cue]
    static let maximumCues = 10_000

    static func parse(_ content: ChapterSubContent) throws -> Self {
        guard content.text.utf8.count <= ChapterSubContent.maximumBytes else { throw SourceSubContentError.budget }
        guard content.failure == nil else {
            switch content.failure {
            case .rule: throw SourceSubContentError.rule
            case .budget: throw SourceSubContentError.budget
            default: throw SourceSubContentError.request
            }
        }
        return try SourcePerfTrace.span("chapter.subContent.parse", "bytes=\(content.text.utf8.count) main=\(Thread.isMainThread)") {
            var values: [(Double?, String)] = []
            if content.kind == .danmaku && content.text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("<") {
                let collector = DanmakuXMLCollector()
                let parser = XMLParser(data: Data(content.text.utf8))
                parser.shouldResolveExternalEntities = false
                parser.delegate = collector
                guard !content.text.localizedCaseInsensitiveContains("<!DOCTYPE"), parser.parse(), !collector.rejected else {
                    throw SourceSubContentError.format
                }
                values = collector.values.map { (Optional($0.0), $0.1) }
            } else {
                if content.kind == .danmaku, !content.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    throw SourceSubContentError.format
                }
                let pattern = try NSRegularExpression(pattern: #"\[(\d+):(\d{1,2}(?:\.\d+)?)\]"#)
                for line in content.text.components(separatedBy: .newlines) where !line.isEmpty {
                    let range = NSRange(line.startIndex..., in: line)
                    let matches = pattern.matches(in: line, range: range)
                    let text = pattern.stringByReplacingMatches(in: line, range: range, withTemplate: "").trimmingCharacters(in: .whitespaces)
                    if matches.isEmpty {
                        if !text.isEmpty { values.append((nil, text)) }
                    } else {
                        for match in matches {
                            let ns = line as NSString
                            guard let minutes = Double(ns.substring(with: match.range(at: 1))),
                                  let seconds = Double(ns.substring(with: match.range(at: 2))), seconds < 60,
                                  minutes < 100_000 else { throw SourceSubContentError.format }
                            if text.isEmpty { continue }
                            values.append((minutes * 60 + seconds, text))
                        }
                    }
                    guard values.count <= maximumCues else { throw SourceSubContentError.budget }
                }
            }
            let ordered = values.enumerated().sorted { left, right in
                let a = left.element.0 ?? -1, b = right.element.0 ?? -1
                return a == b ? left.offset < right.offset : a < b
            }
            return Self(cues: ordered.enumerated().map { Cue(id: $0.offset, seconds: $0.element.element.0, text: $0.element.element.1) })
        }
    }
}

private final class DanmakuXMLCollector: NSObject, XMLParserDelegate {
    var values: [(Double, String)] = []
    var rejected = false
    private var time: Double?
    private var text = ""
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String]) {
        guard elementName == "d" else { return }
        guard let field = attributeDict["p"]?.split(separator: ",").first,
              let value = Double(field), value.isFinite, value >= 0, value < 6_000_000 else {
            rejected = true; parser.abortParsing(); return
        }
        time = value; text = ""
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) { if time != nil { text += string } }
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        guard elementName == "d", let time else { return }
        if !text.isEmpty { values.append((time, text)) }
        self.time = nil; text = ""
        if values.count > ChapterSubContentDocument.maximumCues { rejected = true; parser.abortParsing() }
    }
}
