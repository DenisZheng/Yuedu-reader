import CoreText
import Testing
import UIKit
import YueduCoreText
@testable import yuedu_app

/// 自建数据补足上游依赖私人EPUB而跳过的覆盖；不冒称替代那些原书验收。
@Suite("CoreText图片与装饰块字符串边界", .serialized)
@MainActor
struct CoreTextImageBoundaryTests {
    @Test("图片行判定不把Unicode正文当作空白")
    func standaloneImagePreservesUnicodeBoundaries() {
        let samples: [(String, Bool)] = [(" \u{FFFC}\t", true), ("图\u{FFFC}", false), ("👩‍💻\u{FFFC}", false)]
        for (text, expected) in samples {
            let attributed = NSAttributedString(string: text, attributes: [.font: UIFont.systemFont(ofSize: 17)])
            let range = (text as NSString).range(of: "\u{FFFC}")
            let line = CTLineCreateWithAttributedString(attributed)
            #expect(CoreTextPaginator.isStandaloneImageRun(
                CFRange(location: range.location, length: range.length), line: line, attrStr: attributed
            ) == expected)
        }
    }

    @Test("直排显式装饰块保留正文及有效几何")
    func verticalExplicitDecorationPreservesSourceText() async throws {
        let config = HTMLAttributedStringBuilder.Config(
            fontSize: 17, lineHeightMultiple: 1.5, lineSpacing: 0, paragraphSpacing: 8,
            firstLineIndent: 0, textColor: .black, backgroundColor: .white,
            renderWidth: 260, writingMode: .verticalRTL
        )
        let attributed = await EPUBTestFixtures.renderIR(
            html: EPUBTestFixtures.xhtml(title: "装饰测试", body: """
            <div style="height:48px;width:160px;background-color:#ddeeff;border:1px solid black">装饰正文👩‍💻</div>
            """), config: config
        )
        let layout = await CoreTextPaginator().paginate(
            spineIndex: 0, attrStr: attributed, renderSize: CGSize(width: 320, height: 480),
            fontSize: 17, writingMode: .verticalRTL, revision: ContentRevision()
        )
        let decoration = try #require(layout.blockRenderables.values.flatMap { $0 }.first {
            $0.style.height != nil && $0.style.backgroundFillColor != nil
        })
        #expect(decoration.rect.width > 0 && decoration.rect.height >= 48)
        #expect(layout.attributedString.string.contains("装饰正文👩‍💻"))
        #expect(!layout.isPartial)
        #expect(layout.pageRanges.last.map { $0.location + $0.length } == attributed.length)
    }
}
