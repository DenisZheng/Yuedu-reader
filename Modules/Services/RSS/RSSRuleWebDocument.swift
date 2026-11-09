import Foundation

/// 规则HTML不经过普通Feed净化。只按源合同插入CSS/启动JS，保留原脚本、iframe和相对地址。
/// 创建调用方必须在共享脚本执行器上准备大HTML，不能在View.body里扫描/改写。
struct RSSRuleWebDocument: Sendable {
    let html: String
    let baseURL: URL?

    init(content: String, base: String, source: RSSSource, isStartup: Bool) {
        var value = content
        if isStartup, let script = source.startJs, !script.isEmpty {
            let inserted = "<script>\(script)</script>"
            if let end = value.range(of: "</body>", options: .caseInsensitive) {
                value.insert(contentsOf: inserted, at: end.lowerBound)
            } else { value = "<body>" + value + inserted + "</body>" }
        }
        let configuredStyle = isStartup ? source.startStyle ?? source.style : source.style
        if let end = value.range(of: "</style>", options: .caseInsensitive) {
            if let style = configuredStyle, !style.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                value.insert(contentsOf: "<style>\(style)</style>", at: end.upperBound)
            }
        } else {
            let style = configuredStyle?.trimmingCharacters(in: .whitespacesAndNewlines)
            let css = style?.isEmpty == false ? style! : Self.defaultStyle
            let inserted = "<style>\(css)</style>"
            if let head = value.range(of: "</head>", options: .caseInsensitive) {
                value.insert(contentsOf: inserted, at: head.lowerBound)
            } else { value = inserted + value }
        }
        html = value
        baseURL = source.loadWithBaseUrl ? URL(string: base) : nil
    }

    private static let defaultStyle =
        "img{max-width:100% !important;width:auto;height:auto;}video{object-fit:fill;max-width:100% !important;width:auto;height:auto;}body{word-wrap:break-word;height:auto;max-width:100%;width:auto;}"
}
