import Foundation
import Testing

@testable import yuedu_app

@Suite("首批规则与配置合同", .serialized)
struct FirstParityContractTests {
    private let json = #"{"bookSourceUrl":"https://example.invalid/books#original","bookSourceName":"合成源","mainJs":"function search(){return []}","future":{"items":[null,true,42,"值"]},"ruleSearch":{"bookList":"article","futureSelector":{"enabled":true}},"ruleContent":{"content":"body@html","subContent":"aside@text","maxBatchSize":3},"ruleReview":{"enabled":true,"detailListRule":".reviews"}}"#

    @Test("原正则的禁止回溯语义不能被转换改变", arguments: ["a++a", "(?>a+)a"])
    func regexRetainsMatchingSemantics(_ pattern: String) throws {
        let regex = try #require(RegexCache.shared.regex(for: pattern))
        #expect(regex.firstMatch(in: "aa", range: NSRange(location: 0, length: 2)) == nil)
        #expect(RegexCache.shared.replaceMatches(in: "aa", pattern: pattern, replacement: "X") == "aa")
    }

    @Test("导入导出保留顶层和规则中的未知配置")
    func preservesUnknownConfiguration() throws {
        let source = try JSONDecoder().decode(BookSource.self, from: Data(json.utf8))
        let result = try object(source)
        #expect(result["mainJs"] as? String == "function search(){return []}")
        #expect((result["future"] as? NSDictionary)?.isEqual(to: ["items": [NSNull(), true, 42, "值"]]) == true)
        #expect((result["ruleSearch"] as? [String: Any])?["futureSelector"] as? [String: Bool] == ["enabled": true])
        #expect((result["ruleContent"] as? [String: Any])?["subContent"] as? String == "aside@text")
        #expect((result["ruleReview"] as? [String: Any])?["detailListRule"] as? String == ".reviews")
    }

    @Test("编辑已知字段不恢复旧值或丢失扩展字段")
    func editingKeepsExtensions() throws {
        var source = try JSONDecoder().decode(BookSource.self, from: Data(json.utf8))
        source.bookSourceName = "新名称"
        source.ruleContent.content = "main@html"
        let result = try object(source)
        #expect(result["bookSourceName"] as? String == "新名称")
        #expect((result["ruleContent"] as? [String: Any])?["content"] as? String == "main@html")
        #expect((result["ruleContent"] as? [String: Any])?["subContent"] as? String == "aside@text")
    }

    @Test("扩展配置变化参与修订比较")
    func extensionChangesAreNotNoOp() throws {
        let first = try JSONDecoder().decode(BookSource.self, from: Data(json.utf8))
        var second = try JSONDecoder().decode(BookSource.self, from: Data(json.replacingOccurrences(of: "aside@text", with: "footer@text").utf8))
        second.id = first.id
        #expect(!first.hasSameContent(as: second))
    }

    @Test("文件源不能落入文本目录路径")
    func fileSourceIsNotText() {
        #expect(OnlineBookContentInference.infer(sourceType: 3) != .text)
    }

    @Test("文件源详情实际提取有序下载链接")
    func extractsFileDownloadLinks() async throws {
        var source = BookSource(bookSourceUrl: "https://example.invalid", bookSourceName: "合成文件源")
        source.bookSourceType = 3
        source.ruleBookInfo.name = "h1@text"
        source.ruleBookInfo.downloadUrls = "a@href"
        let book = try await BookSourceSession.session(for: source).parse { bridge in
            try bridge.parseBookInfo(html: "<h1>合成书</h1><a href='/one.txt'>TXT</a><a href='/two.epub'>EPUB</a>",
                bookUrl: "https://example.invalid/book", baseURL: "https://example.invalid/book", source: source)
        }
        let result = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(book)) as? [String: Any])
        #expect(result["downloadUrls"] as? [String] == ["https://example.invalid/one.txt", "https://example.invalid/two.epub"])
        #expect(book.tocUrl.isEmpty)
    }

    private func object(_ source: BookSource) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(source)) as? [String: Any])
    }
}
